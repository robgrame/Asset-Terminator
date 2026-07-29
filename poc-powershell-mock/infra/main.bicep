// Asset-Terminator PowerShell single-function mock -- infrastructure.
//
// Topology (deliberately minimal):
//   * App Service Plan  : Linux, B1 (Basic, dedicated), Always On.
//   * Function App      : PowerShell 7.4, Linux, Functions v4.
//   * Storage account   : Functions host storage (identity-based, no shared key).
//   * Application Insights (+ Log Analytics workspace as its backing store).
//
// NOT deployed on purpose: NO Key Vault, NO App Configuration. The only
// supporting/observability service is Application Insights.
//
// Microsoft Graph is called by the app with an app registration + client secret
// (client credentials) -- see Modules/Graph.psm1. The managed identity below is
// used ONLY to authenticate the Functions host to its storage account.
// ALL application configuration is passed as Function App Application Settings.

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
@description('Short resource name prefix.')
param namePrefix string = 'attmock'

@description('Deployment location.')
param location string = resourceGroup().location

@description('Environment suffix.')
param env string = 'dev'

// --- Graph credentials (app registration + secret) -------------------------
@description('Entra tenant (directory) ID for the Graph app registration.')
param graphTenantId string

@description('Application (client) ID of the Graph app registration.')
param graphClientId string

@description('Client secret of the Graph app registration.')
@secure()
param graphClientSecret string

// --- Graph / behaviour configuration (all become Application Settings) ------
@description('Microsoft Graph base endpoint.')
param graphBaseUri string = 'https://graph.microsoft.com/beta'

@description('Entra authority host (change for sovereign clouds).')
param graphAuthorityHost string = 'https://login.microsoftonline.com'

@description('OAuth2 scope for the client-credentials token.')
param graphScope string = 'https://graph.microsoft.com/.default'

@description('Retries on transient Graph errors (429/5xx).')
param graphMaxRetries int = 4

@description('Default dryRun when the request omits it.')
param defaultDryRun bool = false

@description('keepEnrollmentData flag on the Intune wipe.')
param wipeKeepEnrollmentData bool = false

@description('keepUserData flag on the Intune wipe.')
param wipeKeepUserData bool = false

@description('Reach the host storage account over a private endpoint (required when Azure Policy forces publicNetworkAccess=Disabled on storage accounts).')
param usePrivateEndpoints bool = true

@description('Address space of the VNet created for private connectivity.')
param vnetAddressPrefix string = '10.60.0.0/22'

@description('Subnet delegated to the App Service plan for regional VNet integration.')
param integrationSubnetPrefix string = '10.60.0.0/26'

@description('Subnet hosting the storage private endpoints.')
param privateEndpointSubnetPrefix string = '10.60.0.64/26'

// ---------------------------------------------------------------------------
// Names / tags
// ---------------------------------------------------------------------------
var suffix = uniqueString(resourceGroup().id)

var uamiName = '${namePrefix}-uami-${env}'
var storageName = take(toLower('${namePrefix}host${suffix}'), 24)
var lawName = '${namePrefix}-law-${env}'
var aiName = '${namePrefix}-appi-${env}'
var planName = '${namePrefix}-plan-${env}'
var functionAppName = '${namePrefix}-func-${env}'
var vnetName = '${namePrefix}-vnet-${env}'
var integrationSubnetName = 'snet-integration'
var privateEndpointSubnetName = 'snet-privateendpoints'
var privateStorageServices = [
  'blob'
  'queue'
  'table'
  'file'
]

var tags = {
  solution: 'Asset-Terminator-Mock'
  env: env
}

// Built-in role definition IDs (storage data planes).
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

// ---------------------------------------------------------------------------
// Managed identity (host storage auth only)
// ---------------------------------------------------------------------------
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// Observability -- Application Insights (workspace-based)
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
// Storage -- Functions host (identity-based, shared key disabled)
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

var blobUri = storage.properties.primaryEndpoints.blob
var queueUri = storage.properties.primaryEndpoints.queue
var tableUri = storage.properties.primaryEndpoints.table

// ---------------------------------------------------------------------------
// Private connectivity -- VNet + private endpoints for the host storage.
//
// Required because tenant policy forces publicNetworkAccess=Disabled on
// storage accounts: the Functions host can only reach its host storage from
// inside the VNet.
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

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for svc in privateStorageServices: if (usePrivateEndpoints) {
  name: 'privatelink.${svc}.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}]

resource privateDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (svc, i) in privateStorageServices: if (usePrivateEndpoints) {
  name: '${privateDnsZones[i].name}/link-${vnetName}'
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

resource privateEndpointDnsGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = [for (svc, i) in privateStorageServices: if (usePrivateEndpoints) {
  name: '${storagePrivateEndpoints[i].name}/default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config'
        properties: { privateDnsZoneId: privateDnsZones[i].id }
      }
    ]
  }
  dependsOn: [ privateDnsLinks ]
}]

// ---------------------------------------------------------------------------
// App Service Plan -- Linux, B1 (Basic, dedicated)
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
    reserved: true // Linux
  }
}

// ---------------------------------------------------------------------------
// Function App -- PowerShell 7.4, Linux, Always On
// ---------------------------------------------------------------------------
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
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
      appSettings: [
        // --- Functions runtime -------------------------------------------
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        { name: 'FUNCTIONS_WORKER_RUNTIME_VERSION', value: '7.4' }
        // --- Host storage via managed identity (no shared key) -----------
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: blobUri }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: queueUri }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: tableUri }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId', value: uami.properties.clientId }
        // --- Observability (Application Insights only) -------------------
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        // --- Application configuration (all via app settings) -----------
        { name: 'GRAPH_TENANT_ID', value: graphTenantId }
        { name: 'GRAPH_CLIENT_ID', value: graphClientId }
        { name: 'GRAPH_CLIENT_SECRET', value: graphClientSecret }
        { name: 'GRAPH_BASE_URI', value: graphBaseUri }
        { name: 'GRAPH_AUTHORITY_HOST', value: graphAuthorityHost }
        { name: 'GRAPH_SCOPE', value: graphScope }
        { name: 'GRAPH_MAX_RETRIES', value: string(graphMaxRetries) }
        { name: 'DEFAULT_DRY_RUN', value: toLower(string(defaultDryRun)) }
        { name: 'WIPE_KEEP_ENROLLMENT_DATA', value: toLower(string(wipeKeepEnrollmentData)) }
        { name: 'WIPE_KEEP_USER_DATA', value: toLower(string(wipeKeepUserData)) }
      ]
    }
  }
  dependsOn: usePrivateEndpoints ? [ privateEndpointDnsGroups ] : []
}

// ---------------------------------------------------------------------------
// Role assignments -- host storage (blob owner + queue + table) to the UAMI
// ---------------------------------------------------------------------------
var hostStorageRoles = [
  storageBlobDataOwnerRoleId
  storageQueueDataContributorRoleId
  storageTableDataContributorRoleId
]

resource hostStorageRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in hostStorageRoles: {
  name: guid(storage.id, uami.id, roleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}]

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output functionAppName string = functionApp.name
output functionAppHostName string = functionApp.properties.defaultHostName
output uamiClientId string = uami.properties.clientId
output appInsightsName string = appInsights.name
