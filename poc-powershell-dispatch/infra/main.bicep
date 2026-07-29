// Asset-Terminator dispatch PoC -- infrastructure.
//
// Evolution of poc-powershell-mock: the wipe is no longer executed by the HTTP
// function. The intake publishes on a Service Bus topic and a separate worker
// Function App starts the customer's platform-specific Azure Automation
// runbooks.
//
// Topology:
//   * App Service Plan   : Linux, B1, shared by both Function Apps.
//   * Function App (api) : HTTP intake + status. Identity: uami-api.
//   * Function App (wrk) : Service Bus + timer triggers. Identity: uami-worker.
//   * Service Bus        : topic `asset-disposal`, one subscription per platform.
//   * Automation Account : hosts the three disposal runbooks.
//   * Storage            : Functions host storage + `wiperequests` state table.
//   * Application Insights (+ Log Analytics).
//
// Privilege separation is deliberate: only the worker identity can start
// runbooks; only the api identity is reachable from the internet.

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
param graphAuthorityHost string = 'https://login.microsoftonline.com'

@description('OAuth2 scope for the client-credentials token.')
param graphScope string = 'https://graph.microsoft.com/.default'

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
    runbook: 'Windows_Disposal_Device'
    parameters: {
      SerialNumbers: '$.device.serialNumber'
      RequestId: '$.requestId'
      Scenario: '$.scenario'
      DryRun: '$.options.dryRun'
    }
    timeoutMinutes: 20
  }
  Apple: {
    runbook: 'APPLE_Device_Disposal'
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
    runbook: 'ITA_SAMSUNG_KME_Device_Disposal'
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
@description('Reach storage and Service Bus over private endpoints (required when Azure Policy forces publicNetworkAccess=Disabled).')
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
var uamiWorkerName = '${namePrefix}-uami-wrk-${env}'
var storageName = take(toLower('${namePrefix}host${suffix}'), 24)
var lawName = '${namePrefix}-law-${env}'
var aiName = '${namePrefix}-appi-${env}'
var planName = '${namePrefix}-plan-${env}'
var apiAppName = '${namePrefix}-func-api-${env}'
var workerAppName = '${namePrefix}-func-wrk-${env}'
var serviceBusName = '${namePrefix}-sb-${env}-${suffix}'
var automationAccountName = '${namePrefix}-auto-${env}'
var vnetName = '${namePrefix}-vnet-${env}'

var integrationSubnetName = 'snet-integration'
var privateEndpointSubnetName = 'snet-privateendpoints'
var stateTableName = 'wiperequests'
var topicName = 'asset-disposal'

var platforms = [
  'Windows'
  'Apple'
  'Android'
]

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
var serviceBusDataSenderRoleId = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
var serviceBusDataReceiverRoleId = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
var automationJobOperatorRoleId = '4fe576fe-1146-4730-92eb-48519fa6bf9f'

// ---------------------------------------------------------------------------
// Managed identities -- one per Function App (privilege separation)
// ---------------------------------------------------------------------------
resource uamiApi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiApiName
  location: location
  tags: tags
}

resource uamiWorker 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiWorkerName
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
// Service Bus -- topic with one subscription per platform
// ---------------------------------------------------------------------------
resource serviceBus 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: serviceBusName
  location: location
  tags: tags
  sku: {
    name: 'Standard' // topics require Standard or higher
    tier: 'Standard'
  }
  properties: {
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
  }
}

resource topic 'Microsoft.ServiceBus/namespaces/topics@2024-01-01' = {
  parent: serviceBus
  name: topicName
  properties: {
    // MessageId = requestId, so a ServiceNow retry never creates a second job.
    requiresDuplicateDetection: true
    duplicateDetectionHistoryTimeWindow: 'PT1H'
    defaultMessageTimeToLive: 'P14D'
    supportOrdering: true
  }
}

resource subscriptions 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2024-01-01' = [for platform in platforms: {
  parent: topic
  name: 'sub-${toLower(platform)}'
  properties: {
    // SessionId = serialNumber: two requests on the same device never run in parallel.
    requiresSession: true
    lockDuration: 'PT5M'
    maxDeliveryCount: 5
    deadLetteringOnMessageExpiration: true
    defaultMessageTimeToLive: 'P14D'
  }
}]

resource subscriptionRules 'Microsoft.ServiceBus/namespaces/topics/subscriptions/rules@2024-01-01' = [for (platform, i) in platforms: {
  parent: subscriptions[i]
  name: 'platform-filter'
  properties: {
    filterType: 'SqlFilter'
    sqlFilter: {
      sqlExpression: 'platform = \'${platform}\''
    }
  }
}]

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
]

var automationSecretVariables = [
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
  'Windows_Disposal_Device'
  'APPLE_Device_Disposal'
  'ITA_SAMSUNG_KME_Device_Disposal'
]

resource runbooks 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = [for name in runbookNames: {
  parent: automation
  name: name
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell'
    logProgress: false
    logVerbose: false
    description: 'Asset disposal runbook dispatched by the worker function app.'
  }
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
// App Service Plan -- shared by both Function Apps
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
  { name: 'FUNCTIONS_WORKER_RUNTIME_VERSION', value: '7.4' }
  { name: 'AzureWebJobsStorage__accountName', value: storage.name }
  { name: 'AzureWebJobsStorage__blobServiceUri', value: blobUri }
  { name: 'AzureWebJobsStorage__queueServiceUri', value: queueUri }
  { name: 'AzureWebJobsStorage__tableServiceUri', value: tableUri }
  { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
  { name: 'STATE_TABLE_ENDPOINT', value: tableUri }
  { name: 'STATE_TABLE_NAME', value: stateTableName }
  { name: 'SERVICEBUS_FQDN', value: '${serviceBus.name}.servicebus.windows.net' }
  { name: 'SERVICEBUS_TOPIC', value: topicName }
]

// ---------------------------------------------------------------------------
// Function App -- api (internet facing, Graph read only)
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
      linuxFxVersion: 'POWERSHELL|7.4'
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
      ])
    }
  }
  dependsOn: usePrivateEndpoints ? [ storagePrivateEndpointDns ] : []
}

// ---------------------------------------------------------------------------
// Function App -- worker (no public trigger, starts runbooks)
// ---------------------------------------------------------------------------
resource workerApp 'Microsoft.Web/sites@2023-12-01' = {
  name: workerAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uamiWorker.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: usePrivateEndpoints ? '${vnet.id}/subnets/${integrationSubnetName}' : null
    vnetRouteAllEnabled: usePrivateEndpoints
    siteConfig: {
      linuxFxVersion: 'POWERSHELL|7.4'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: usePrivateEndpoints
      appSettings: concat(hostStorageSettings, [
        { name: 'AzureWebJobsStorage__clientId', value: uamiWorker.properties.clientId }
        { name: 'UAMI_CLIENT_ID', value: uamiWorker.properties.clientId }
        // Service Bus trigger over managed identity (no connection string).
        { name: 'ServiceBusConnection__fullyQualifiedNamespace', value: '${serviceBus.name}.servicebus.windows.net' }
        { name: 'ServiceBusConnection__credential', value: 'managedidentity' }
        { name: 'ServiceBusConnection__clientId', value: uamiWorker.properties.clientId }
        { name: 'AUTOMATION_SUBSCRIPTION_ID', value: subscription().subscriptionId }
        { name: 'AUTOMATION_RESOURCE_GROUP', value: resourceGroup().name }
        { name: 'AUTOMATION_ACCOUNT_NAME', value: automation.name }
        { name: 'DISPATCH_MODE', value: 'arm' }
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

resource workerStorageRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in hostStorageRoles: {
  name: guid(storage.id, uamiWorker.id, roleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    principalId: uamiWorker.properties.principalId
    principalType: 'ServicePrincipal'
  }
}]

// The api can only send; the worker can only receive.
resource apiServiceBusSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBus.id, uamiApi.id, serviceBusDataSenderRoleId)
  scope: serviceBus
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceBusDataSenderRoleId)
    principalId: uamiApi.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource workerServiceBusReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBus.id, uamiWorker.id, serviceBusDataReceiverRoleId)
  scope: serviceBus
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceBusDataReceiverRoleId)
    principalId: uamiWorker.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Only the worker may start runbook jobs.
resource workerAutomationOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automation.id, uamiWorker.id, automationJobOperatorRoleId)
  scope: automation
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', automationJobOperatorRoleId)
    principalId: uamiWorker.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output apiAppName string = apiApp.name
output apiAppHostName string = apiApp.properties.defaultHostName
output workerAppName string = workerApp.name
output serviceBusNamespace string = serviceBus.name
output automationAccountName string = automation.name
output stateTableName string = stateTableName
output apiIdentityClientId string = uamiApi.properties.clientId
output workerIdentityClientId string = uamiWorker.properties.clientId
