// Asset-Terminator PowerShell POC -- two-app topology.
//
// Two separate Function Apps, each with its own User-Assigned Managed Identity:
//   * Intake  (internet-facing): HTTP intake + status query. Can ONLY send to the
//             Service Bus queue and read/write the state table. NO Graph access.
//   * Processor (internal): Service Bus-triggered worker that resolves the device,
//             evaluates guardrails and issues the Intune wipe. Holds the
//             privileged Microsoft Graph permissions.
//
// A dedicated storage account hosts the Table Storage state store (idempotency +
// status tracking), separate from the Functions host/deployment storage.

@description('Short resource name prefix.')
param namePrefix string = 'attpoc'

@description('Deployment location.')
param location string = resourceGroup().location

@description('Environment suffix.')
param env string = 'dev'

@description('Service Bus queue name for wipe requests.')
param queueName string = 'wipe-requests'

@description('State table name.')
param stateTableName string = 'DecommissionState'

var suffix = uniqueString(resourceGroup().id)

var hostStorageName = take(toLower('${namePrefix}host${suffix}'), 24)
var stateStorageName = take(toLower('${namePrefix}state${suffix}'), 24)
var sbNamespaceName = '${namePrefix}-sb-${env}'
var lawName = '${namePrefix}-law-${env}'
var aiName = '${namePrefix}-appi-${env}'

var intakeUamiName = '${namePrefix}-intake-uami-${env}'
var processorUamiName = '${namePrefix}-processor-uami-${env}'
var intakePlanName = '${namePrefix}-intake-plan-${env}'
var processorPlanName = '${namePrefix}-processor-plan-${env}'
var intakeFuncName = '${namePrefix}-intake-${env}'
var processorFuncName = '${namePrefix}-processor-${env}'

var intakePackageContainer = 'app-package-intake'
var processorPackageContainer = 'app-package-processor'

var tags = {
  solution: 'Asset-Terminator-POC'
  env: env
}

// Built-in role definition IDs.
var serviceBusDataSenderRoleId = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
var serviceBusDataReceiverRoleId = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

// ---------------------------------------------------------------------------
// Identities
// ---------------------------------------------------------------------------
resource intakeUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: intakeUamiName
  location: location
  tags: tags
}

resource processorUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: processorUamiName
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
// Storage -- Functions host/deployment (shared) + dedicated state table
// ---------------------------------------------------------------------------
resource hostStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: hostStorageName
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

resource hostBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: hostStorage
  name: 'default'
}

resource intakeContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: hostBlob
  name: intakePackageContainer
  properties: { publicAccess: 'None' }
}

resource processorContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: hostBlob
  name: processorPackageContainer
  properties: { publicAccess: 'None' }
}

resource stateStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: stateStorageName
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

resource stateTableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: stateStorage
  name: 'default'
}

resource stateTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: stateTableService
  name: stateTableName
}

// ---------------------------------------------------------------------------
// Messaging
// ---------------------------------------------------------------------------
resource serviceBus 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: sbNamespaceName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    minimumTlsVersion: '1.2'
  }
}

resource wipeQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: serviceBus
  name: queueName
  properties: {
    maxDeliveryCount: 5
    lockDuration: 'PT5M'
    deadLetteringOnMessageExpiration: true
  }
}

// ---------------------------------------------------------------------------
// Flex Consumption plans (one per app)
// ---------------------------------------------------------------------------
resource intakePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: intakePlanName
  location: location
  tags: tags
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  kind: 'functionapp'
  properties: { reserved: true }
}

resource processorPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: processorPlanName
  location: location
  tags: tags
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  kind: 'functionapp'
  properties: { reserved: true }
}

var hostBlobUri = hostStorage.properties.primaryEndpoints.blob
var hostQueueUri = hostStorage.properties.primaryEndpoints.queue
var hostTableUri = hostStorage.properties.primaryEndpoints.table

// Common app settings shared by both Function Apps. clientId differs per app.
var commonStorageSettings = [
  { name: 'AzureWebJobsStorage__accountName', value: hostStorage.name }
  { name: 'AzureWebJobsStorage__blobServiceUri', value: hostBlobUri }
  { name: 'AzureWebJobsStorage__queueServiceUri', value: hostQueueUri }
  { name: 'AzureWebJobsStorage__tableServiceUri', value: hostTableUri }
  { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
  { name: 'STATE_TABLE_ACCOUNT', value: stateStorage.name }
  { name: 'STATE_TABLE_NAME', value: stateTableName }
  { name: 'ServiceBusConnection__fullyQualifiedNamespace', value: '${sbNamespaceName}.servicebus.windows.net' }
  { name: 'ServiceBusConnection__credential', value: 'managedidentity' }
]

// ---------------------------------------------------------------------------
// Intake Function App (internet-facing, no Graph)
// ---------------------------------------------------------------------------
resource intakeFunc 'Microsoft.Web/sites@2023-12-01' = {
  name: intakeFuncName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${intakeUami.id}': {}
    }
  }
  properties: {
    serverFarmId: intakePlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${hostBlobUri}${intakePackageContainer}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: intakeUami.id
          }
        }
      }
      runtime: {
        name: 'powershell'
        version: '7.4'
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 40
        alwaysReady: [
          { name: 'http', instanceCount: 1 }
        ]
      }
    }
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: concat(commonStorageSettings, [
        { name: 'AzureWebJobsStorage__clientId', value: intakeUami.properties.clientId }
        { name: 'ServiceBusConnection__clientId', value: intakeUami.properties.clientId }
        { name: 'UAMI_CLIENT_ID', value: intakeUami.properties.clientId }
      ])
    }
  }
}

// ---------------------------------------------------------------------------
// Processor Function App (internal, Graph-privileged)
// ---------------------------------------------------------------------------
resource processorFunc 'Microsoft.Web/sites@2023-12-01' = {
  name: processorFuncName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${processorUami.id}': {}
    }
  }
  properties: {
    serverFarmId: processorPlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${hostBlobUri}${processorPackageContainer}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: processorUami.id
          }
        }
      }
      runtime: {
        name: 'powershell'
        version: '7.4'
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 40
        alwaysReady: [
          { name: 'function:WipeProcessor', instanceCount: 1 }
        ]
      }
    }
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: concat(commonStorageSettings, [
        { name: 'AzureWebJobsStorage__clientId', value: processorUami.properties.clientId }
        { name: 'ServiceBusConnection__clientId', value: processorUami.properties.clientId }
        { name: 'UAMI_CLIENT_ID', value: processorUami.properties.clientId }
      ])
    }
  }
}

// ---------------------------------------------------------------------------
// Role assignments -- host storage (both identities: blob + queue + table)
// ---------------------------------------------------------------------------
var hostStorageRoles = [
  storageBlobDataOwnerRoleId
  storageQueueDataContributorRoleId
  storageTableDataContributorRoleId
]

resource intakeHostStorageRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in hostStorageRoles: {
  name: guid(hostStorage.id, intakeUami.id, roleId)
  scope: hostStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    principalId: intakeUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource processorHostStorageRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in hostStorageRoles: {
  name: guid(hostStorage.id, processorUami.id, roleId)
  scope: hostStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    principalId: processorUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}]

// ---------------------------------------------------------------------------
// Role assignments -- dedicated state storage (Table Data Contributor)
// ---------------------------------------------------------------------------
resource intakeStateTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stateStorage.id, intakeUami.id, storageTableDataContributorRoleId)
  scope: stateStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
    principalId: intakeUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource processorStateTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stateStorage.id, processorUami.id, storageTableDataContributorRoleId)
  scope: stateStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
    principalId: processorUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Role assignments -- Service Bus (intake sends, processor receives)
// ---------------------------------------------------------------------------
resource intakeSbSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBus.id, intakeUami.id, serviceBusDataSenderRoleId)
  scope: serviceBus
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceBusDataSenderRoleId)
    principalId: intakeUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource processorSbReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(serviceBus.id, processorUami.id, serviceBusDataReceiverRoleId)
  scope: serviceBus
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceBusDataReceiverRoleId)
    principalId: processorUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output intakeFunctionAppName string = intakeFunc.name
output processorFunctionAppName string = processorFunc.name
output intakePrincipalId string = intakeUami.properties.principalId
output processorPrincipalId string = processorUami.properties.principalId
output serviceBusNamespace string = serviceBus.name
output queueName string = queueName
output stateStorageAccount string = stateStorage.name
output stateTableName string = stateTableName
