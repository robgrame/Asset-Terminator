// Asset-Terminator dispatch PoC -- infrastructure.
//
// Evolution of poc-powershell-mock: the HTTP intake validates each request and
// directly starts the customer's platform-specific Azure Automation runbook.
//
// Topology:
//   * App Service Plan   : Linux, B1.
//   * Function App (api) : HTTP intake + status + job monitor. Identity: uami-api.
//   * Automation Account : hosts the three disposal runbooks.
//   * Storage            : Functions host storage + `wiperequests` state table.
//   * Application Insights (+ Log Analytics).
//
// The Function identity can read/write request state and start/monitor runbooks.

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
@description('Short resource name prefix.')
param namePrefix string = 'attdisp'

@description('Deployment location.')
param location string = resourceGroup().location

@description('Environment suffix.')
param env string = 'dev'

// --- Graph credentials used by the intake (read-only lookups) --------------
@description('Entra tenant (directory) ID for the Graph app registration.')
param graphTenantId string

@description('Application (client) ID of the Graph app registration.')
param graphClientId string

@description('Client secret of the Graph app registration.')
@secure()
param graphClientSecret string

@description('Microsoft Graph base endpoint.')
param graphBaseUri string = 'https://graph.microsoft.com/beta'

@description('Entra authority host (change for sovereign clouds).')
param graphAuthorityHost string = environment().authentication.loginEndpoint

@description('OAuth2 scope for the client-credentials token.')
param graphScope string = 'https://graph.microsoft.com/.default'

@description('PowerShell version used by Azure Automation runbooks and the Function App.')
param powerShellVersion string = '7.6'

@description('Microsoft.Graph.Authentication package version installed in the Automation PowerShell Runtime Environment.')
param graphAuthenticationModuleVersion string = '2.39.0'

// --- Behaviour -------------------------------------------------------------
@description('Default dryRun when the request omits it.')
param defaultDryRun bool = false

@description('Require the device to be encrypted before accepting a request.')
param guardrailRequireEncryption bool = true

@description('Require explicit user confirmation before accepting a request.')
param guardrailRequireUserConfirmation bool = true

@description('The bundled runbooks accept -Scenario, so the Retirement scenario is dispatchable. Set to false only if you replace them with runbooks that do not.')
param runbooksSupportScenario bool = true

@description('CRON expression for the JobMonitor timer.')
param jobMonitorSchedule string = '0 */2 * * * *'

@description('Platform -> runbook routing table (see docs/evoluzione-dispatch-runbook.md).')
param runbookMap object = {
  Windows: {
    runbook: 'RBK-WindowsDisposal'
    parameters: {
      SerialNumbers: '$.device.serialNumber'
      RequestId: '$.requestId'
      Scenario: '$.scenario'
      DryRun: '$.options.dryRun'
    }
    timeoutMinutes: 20
  }
  Apple: {
    runbook: 'RBK-AppleDisposal'
    parameters: {
      SerialNumbers: '$.device.serialNumber'
      MdmServerId: '$.options.mdmServerId'
      RequestId: '$.requestId'
      Scenario: '$.scenario'
      DryRun: '$.options.dryRun'
    }
    timeoutMinutes: 45
  }
  Android: {
    runbook: 'RBK-AndroidDisposal'
    parameters: {
      Serials: '$.device.serialNumber'
      RequestId: '$.requestId'
      Scenario: '$.scenario'
      DryRun: '$.options.dryRun'
    }
    timeoutMinutes: 20
  }
}

// --- Private connectivity --------------------------------------------------
@description('Reach storage over private endpoints (required when Azure Policy forces publicNetworkAccess=Disabled).')
param usePrivateEndpoints bool = true

@description('Address space of the VNet created for private connectivity.')
param vnetAddressPrefix string = '10.61.0.0/22'

@description('Subnet delegated to the App Service plan for regional VNet integration.')
param integrationSubnetPrefix string = '10.61.0.0/26'

@description('Subnet hosting the private endpoints.')
param privateEndpointSubnetPrefix string = '10.61.0.64/26'

// ---------------------------------------------------------------------------
// Names / tags
// ---------------------------------------------------------------------------
var suffix = uniqueString(resourceGroup().id)

var uamiApiName = '${namePrefix}-uami-api-${env}'
var storageName = take(toLower('${namePrefix}host${suffix}'), 24)
var lawName = '${namePrefix}-law-${env}'
var aiName = '${namePrefix}-appi-${env}'
var planName = '${namePrefix}-plan-${env}'
var apiAppName = '${namePrefix}-func-api-${env}'
var automationAccountName = '${namePrefix}-auto-${env}'
var vnetName = '${namePrefix}-vnet-${env}'

var integrationSubnetName = 'snet-integration'
var privateEndpointSubnetName = 'snet-privateendpoints'
var stateTableName = 'wiperequests'

var privateStorageServices = [
  'blob'
  'queue'
  'table'
  'file'
]

var tags = {
  solution: 'Asset-Terminator-Dispatch'
  env: env
}

// Built-in role definition IDs.
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var automationJobOperatorRoleId = '4fe576fe-1146-4730-92eb-48519fa6bf9f'

// ---------------------------------------------------------------------------
// Managed identity
// ---------------------------------------------------------------------------
resource uamiApi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiApiName
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

// Ad-hoc workbook to monitor the disposal requests end-to-end from the audit
// customEvents emitted by the Function App and runbooks.
resource wipeWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'asset-terminator-wipe-workbook')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'Asset-Terminator — Wipe Requests'
    serializedData: loadTextContent('workbook-wipe.json')
    category: 'workbook'
    sourceId: appInsights.id
    version: 'Notebook/1.0'
  }
}

// ---------------------------------------------------------------------------
// Storage -- Functions host + durable request state
// ---------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource stateTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: stateTableName
}

var blobUri = storage.properties.primaryEndpoints.blob
var queueUri = storage.properties.primaryEndpoints.queue
var tableUri = storage.properties.primaryEndpoints.table

// ---------------------------------------------------------------------------
// Automation Account -- hosts the customer's platform runbooks
// ---------------------------------------------------------------------------
resource automation 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    sku: { name: 'Basic' }
    publicNetworkAccess: true
    disableLocalAuth: false
  }
}

// Automation variables. Runbooks read every secret from here: job parameters are
// stored in clear text in the job metadata and are readable by any Job Reader.
// Secret values are created empty and must be populated out of band (deploy.ps1
// -AutomationVariables, or the portal) so they never land in a template or a
// deployment history entry.
var automationPlainVariables = [
  { name: 'ClientId', value: graphClientId, description: 'Graph app registration (application) ID used by the runbooks.' }
  { name: 'TenantId', value: graphTenantId, description: 'Entra tenant ID.' }
  { name: 'GraphCertificateName', value: 'GraphAppCert', description: 'Name of the Automation Certificate asset holding the Graph app-only certificate used by the runbooks.' }
]

var automationSecretVariables = [
  { name: 'ClientSecret', description: 'Graph app registration client secret (optional fallback used by the runbooks only when no certificate is available).' }
  { name: 'Certificate_thumbprint', description: 'Thumbprint of the certificate used for Graph app-only authentication.' }
  { name: 'ABM-ClientId', description: 'Apple Business Manager API client ID (BUSINESSAPI.<guid>).' }
  { name: 'ABM-KeyId', description: 'Apple Business Manager API key ID.' }
  { name: 'ABM-PrivateKey', description: 'Apple Business Manager EC P-256 private key (PEM).' }
  { name: 'KME-ClientIdentifier', description: 'Samsung Knox API client identifier.' }
  { name: 'KME-KeysJson', description: 'Samsung Knox keys JSON (contains the RSA private key).' }
  { name: 'KME-CustomerId', description: 'Samsung Knox customer ID.' }
]

resource automationPlainVars 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = [for v in automationPlainVariables: {
  parent: automation
  name: v.name
  properties: {
    isEncrypted: false
    description: v.description
    // Automation stores variable values as JSON, so strings must be quoted.
    value: '"${v.value}"'
  }
}]

// Kept out of the for-loop above because its value derives from a resource
// runtime property (ConnectionString), which cannot be evaluated at the start
// of the deployment.
resource automationAiConnVar 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automation
  name: 'AppInsightsConnectionString'
  properties: {
    isEncrypted: false
    description: 'Application Insights connection string used by the runbooks to emit audit customEvents.'
    value: '"${appInsights.properties.ConnectionString}"'
  }
}

resource automationSecretVars 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = [for v in automationSecretVariables: {
  parent: automation
  name: v.name
  properties: {
    isEncrypted: true
    description: '${v.description} Populate this variable after the deployment.'
  }
}]

// Runbook shells. The PowerShell content is uploaded and published by deploy.ps1:
// embedding it here would put it in the deployment history and make every code
// change a template change.
var runbookNames = [
  'RBK-WindowsDisposal'
  'RBK-AppleDisposal'
  'RBK-AndroidDisposal'
]

// The runbooks are linked explicitly to the current PowerShell runtime so they
// never fall back to the legacy 5.1 runtime.
resource powerShellRuntime 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  parent: automation
  name: 'PowerShell-${replace(powerShellVersion, '.', '')}'
  location: location
  tags: tags
  properties: {
    runtime: {
      language: 'PowerShell'
      version: powerShellVersion
    }
  }
}

resource graphAuthenticationPackage 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages@2024-10-23' = {
  parent: powerShellRuntime
  name: 'Microsoft.Graph.Authentication'
  properties: {
    contentLink: {
      uri: 'https://cdn.powershellgallery.com/packages/microsoft.graph.authentication.${graphAuthenticationModuleVersion}.nupkg'
      version: graphAuthenticationModuleVersion
    }
  }
}

resource runbooks 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = [for name in runbookNames: {
  parent: automation
  name: name
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell'
    runtimeEnvironment: powerShellRuntime.name
    logProgress: false
    logVerbose: false
    description: 'Asset disposal runbook dispatched by the Function App (PowerShell ${powerShellVersion}).'
  }
  dependsOn: [
    graphAuthenticationPackage
  ]
}]

// ---------------------------------------------------------------------------
// Private connectivity
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = if (usePrivateEndpoints) {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ vnetAddressPrefix ] }
    subnets: [
      {
        name: integrationSubnetName
        properties: {
          addressPrefix: integrationSubnetPrefix
          delegations: [
            {
              name: 'webapp'
              properties: { serviceName: 'Microsoft.Web/serverFarms' }
            }
          ]
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource storageDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for svc in privateStorageServices: if (usePrivateEndpoints) {
  name: 'privatelink.${svc}.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}]

resource storageDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (svc, i) in privateStorageServices: if (usePrivateEndpoints) {
  name: '${storageDnsZones[i].name}/link-${vnetName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

resource storagePrivateEndpoints 'Microsoft.Network/privateEndpoints@2023-11-01' = [for (svc, i) in privateStorageServices: if (usePrivateEndpoints) {
  name: '${storageName}-pe-${svc}'
  location: location
  tags: tags
  properties: {
    subnet: { id: '${vnet.id}/subnets/${privateEndpointSubnetName}' }
    privateLinkServiceConnections: [
      {
        name: 'pls-${svc}'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [ svc ]
        }
      }
    ]
  }
}]

resource storagePrivateEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = [for (svc, i) in privateStorageServices: if (usePrivateEndpoints) {
  name: '${storagePrivateEndpoints[i].name}/default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config'
        properties: { privateDnsZoneId: storageDnsZones[i].id }
      }
    ]
  }
  dependsOn: [ storageDnsLinks ]
}]

// ---------------------------------------------------------------------------
// App Service Plan
// ---------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  properties: {
    reserved: true
  }
}

// ---------------------------------------------------------------------------
// Common application settings
// ---------------------------------------------------------------------------
var hostStorageSettings = [
  { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
  { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
  { name: 'FUNCTIONS_WORKER_RUNTIME_VERSION', value: powerShellVersion }
  { name: 'AzureWebJobsStorage__accountName', value: storage.name }
  { name: 'AzureWebJobsStorage__blobServiceUri', value: blobUri }
  { name: 'AzureWebJobsStorage__queueServiceUri', value: queueUri }
  { name: 'AzureWebJobsStorage__tableServiceUri', value: tableUri }
  { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
  { name: 'STATE_TABLE_ENDPOINT', value: tableUri }
  { name: 'STATE_TABLE_NAME', value: stateTableName }
]

// ---------------------------------------------------------------------------
// Function App -- intake, direct runbook dispatch, status and job monitor
// ---------------------------------------------------------------------------
resource apiApp 'Microsoft.Web/sites@2023-12-01' = {
  name: apiAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uamiApi.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: usePrivateEndpoints ? '${vnet.id}/subnets/${integrationSubnetName}' : null
    vnetRouteAllEnabled: usePrivateEndpoints
    siteConfig: {
      linuxFxVersion: 'POWERSHELL|${powerShellVersion}'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: usePrivateEndpoints
      appSettings: concat(hostStorageSettings, [
        { name: 'AzureWebJobsStorage__clientId', value: uamiApi.properties.clientId }
        { name: 'UAMI_CLIENT_ID', value: uamiApi.properties.clientId }
        { name: 'GRAPH_TENANT_ID', value: graphTenantId }
        { name: 'GRAPH_CLIENT_ID', value: graphClientId }
        { name: 'GRAPH_CLIENT_SECRET', value: graphClientSecret }
        { name: 'GRAPH_BASE_URI', value: graphBaseUri }
        { name: 'GRAPH_AUTHORITY_HOST', value: graphAuthorityHost }
        { name: 'GRAPH_SCOPE', value: graphScope }
        { name: 'DEFAULT_DRY_RUN', value: toLower(string(defaultDryRun)) }
        { name: 'GUARDRAIL_REQUIRE_ENCRYPTION', value: toLower(string(guardrailRequireEncryption)) }
        { name: 'GUARDRAIL_REQUIRE_USER_CONFIRMATION', value: toLower(string(guardrailRequireUserConfirmation)) }
        { name: 'AUTOMATION_SUBSCRIPTION_ID', value: subscription().subscriptionId }
        { name: 'AUTOMATION_RESOURCE_GROUP', value: resourceGroup().name }
        { name: 'AUTOMATION_ACCOUNT_NAME', value: automation.name }
        { name: 'RUNBOOK_MAP', value: string(runbookMap) }
        { name: 'RUNBOOKS_SUPPORT_SCENARIO', value: toLower(string(runbooksSupportScenario)) }
        { name: 'JOBMONITOR_SCHEDULE', value: jobMonitorSchedule }
      ])
    }
  }
  dependsOn: usePrivateEndpoints ? [ storagePrivateEndpointDns ] : []
}

// ---------------------------------------------------------------------------
// Role assignments
// ---------------------------------------------------------------------------
var hostStorageRoles = [
  storageBlobDataOwnerRoleId
  storageQueueDataContributorRoleId
  storageTableDataContributorRoleId
]

resource apiStorageRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in hostStorageRoles: {
  name: guid(storage.id, uamiApi.id, roleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    principalId: uamiApi.properties.principalId
    principalType: 'ServicePrincipal'
  }
}]

// The Function App starts and monitors Automation jobs.
resource apiAutomationOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automation.id, uamiApi.id, automationJobOperatorRoleId)
  scope: automation
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', automationJobOperatorRoleId)
    principalId: uamiApi.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output apiAppName string = apiApp.name
output apiAppHostName string = apiApp.properties.defaultHostName
output automationAccountName string = automation.name
output stateTableName string = stateTableName
output apiIdentityClientId string = uamiApi.properties.clientId
