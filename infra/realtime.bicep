targetScope = 'resourceGroup'

// -----------------------------------------------------------------------------
// Realtime monitoring PoC: Azure SignalR (Serverless) + Event Grid custom topic
// + a Flex Consumption Function (Event Grid -> SignalR bridge) + a Linux Web App
// serving the live operations board. Deployable standalone into the existing RG.
// -----------------------------------------------------------------------------

@description('Short resource name prefix (aligned with main.bicep).')
param namePrefix string = 'astterm'

@description('Deployment location.')
param location string = resourceGroup().location

@description('Environment suffix.')
param env string = 'dev'

@description('Application Insights connection string to wire the realtime function/web app to.')
param appInsightsConnectionString string = ''

@description('Principal ID of the orchestrator managed identity that publishes state-change events. Granted EventGrid Data Sender on the topic when set.')
param orchestratorPrincipalId string = ''

@description('Create the Event Grid -> Function subscription. Enable only AFTER the function code is published (the function must exist).')
param createEventSubscription bool = false

@description('Event type used for decommission state-change events.')
param eventType string = 'AssetTerminator.DecommissionStateChanged'

var tags = {
  solution: 'Asset-Terminator'
  env: env
  component: 'realtime'
}

var uniqueSuffix = uniqueString(resourceGroup().id, namePrefix, env, 'realtime')
var storagePrefix = toLower(replace(namePrefix, '-', ''))
var storageEnv = toLower(replace(env, '-', ''))

var signalRName = '${namePrefix}-sigr-${env}'
var topicName = '${namePrefix}-egt-decom-${env}'
var functionName = '${namePrefix}-func-realtime-${env}'
var functionPlanName = '${namePrefix}-plan-realtime-${env}'
var functionStorageName = take('${storagePrefix}rtfn${storageEnv}${uniqueSuffix}', 24)

var deploymentContainerName = 'app-package'
var realtimeIdentityName = '${namePrefix}-uami-realtime-${env}'

// Built-in role definition IDs.
var signalRServiceOwnerRoleId = '7e4f1700-ea5a-4f59-8f37-079cfe29dce3'
var eventGridDataSenderRoleId = 'd5a91429-5739-47e2-a06b-3470a27159e7'
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'

// ---------------------------------------------------------------------------
// User-assigned identity for the realtime function (shared-key access is
// disabled by policy, so host/deployment storage must use identity-based auth).
// ---------------------------------------------------------------------------
resource realtimeIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: realtimeIdentityName
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// Azure SignalR Service (Serverless mode)
// ---------------------------------------------------------------------------
resource signalR 'Microsoft.SignalRService/signalR@2024-03-01' = {
  name: signalRName
  location: location
  tags: tags
  sku: {
    name: 'Free_F1'
    tier: 'Free'
    capacity: 1
  }
  kind: 'SignalR'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    features: [
      {
        flag: 'ServiceMode'
        value: 'Serverless'
      }
    ]
    cors: {
      allowedOrigins: [
        '*'
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Event Grid custom topic
// ---------------------------------------------------------------------------
resource topic 'Microsoft.EventGrid/topics@2024-06-01-preview' = {
  name: topicName
  location: location
  tags: tags
  properties: {
    inputSchema: 'EventGridSchema'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }
}

// ---------------------------------------------------------------------------
// Function host storage (Flex Consumption, identity-based access)
// ---------------------------------------------------------------------------
resource functionStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: functionStorageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource functionBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: functionStorage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: functionBlobService
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

// ---------------------------------------------------------------------------
// Function App (Flex Consumption, dotnet-isolated) — EventGrid -> SignalR bridge
// ---------------------------------------------------------------------------
resource functionPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: functionPlanName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${realtimeIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: functionPlan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${functionStorage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: realtimeIdentity.id
          }
        }
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'AzureWebJobsStorage__accountName'
          value: functionStorage.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureWebJobsStorage__clientId'
          value: realtimeIdentity.properties.clientId
        }
        {
          name: 'AZURE_CLIENT_ID'
          value: realtimeIdentity.properties.clientId
        }
        // SignalR output/negotiate binding connection (identity-based, serverless).
        {
          name: 'AzureSignalRConnectionString__serviceUri'
          value: signalR.properties.hostName == '' ? 'https://${signalRName}.service.signalr.net' : 'https://${signalR.properties.hostName}'
        }
        {
          name: 'AzureSignalRConnectionString__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureSignalRConnectionString__clientId'
          value: realtimeIdentity.properties.clientId
        }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
  }
  dependsOn: [
    deploymentContainer
    functionStorageBlobRole
    functionStorageQueueRole
  ]
}

// ---------------------------------------------------------------------------
// RBAC
// ---------------------------------------------------------------------------

// Function needs SignalR Service Owner: both output-binding broadcast AND
// generating client access tokens for the /negotiate endpoint.
resource functionSignalRRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(signalR.id, realtimeIdentity.id, signalRServiceOwnerRoleId)
  scope: signalR
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', signalRServiceOwnerRoleId)
    principalId: realtimeIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Web app negotiate is served by the function app itself (see HttpEndpoints);
// the function's SignalR Service Owner role also covers negotiate token generation.

// Function host storage access (blob + queue) via managed identity.
resource functionStorageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionStorage.id, realtimeIdentity.id, storageBlobDataOwnerRoleId)
  scope: functionStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: realtimeIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource functionStorageQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionStorage.id, realtimeIdentity.id, storageQueueDataContributorRoleId)
  scope: functionStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
    principalId: realtimeIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Orchestrator identity -> publish to the custom topic.
resource orchestratorTopicRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(orchestratorPrincipalId)) {
  name: guid(topic.id, orchestratorPrincipalId, eventGridDataSenderRoleId)
  scope: topic
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventGridDataSenderRoleId)
    principalId: orchestratorPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Event Grid subscription: topic -> function (enable after code is published)
// ---------------------------------------------------------------------------
resource eventSubscription 'Microsoft.EventGrid/topics/eventSubscriptions@2024-06-01-preview' = if (createEventSubscription) {
  parent: topic
  name: 'to-realtime-function'
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '${functionApp.id}/functions/OnDecommissionStateChanged'
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        eventType
      ]
    }
    eventDeliverySchema: 'EventGridSchema'
  }
}

output signalRName string = signalR.name
output signalREndpoint string = 'https://${signalR.properties.hostName}'
output topicName string = topic.name
output topicEndpoint string = topic.properties.endpoint
output functionAppName string = functionApp.name
output functionDefaultHostName string = functionApp.properties.defaultHostName
output boardUrl string = 'https://${functionApp.properties.defaultHostName}/'
