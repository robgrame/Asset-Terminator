param location string
param tags object
param appName string
param planName string
param deploymentStorageName string
param managedIdentityClientId string
param managedIdentityResourceId string
param appInsightsConnectionString string
param sqlServerFqdn string
param sqlDatabaseName string
param auditBlobServiceUri string
param serviceBusFqdn string
param keyVaultUri string

var deploymentContainerName = 'app-package'

resource deploymentStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: deploymentStorageName
}

resource deploymentBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: deploymentStorage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: deploymentBlobService
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
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
  name: appName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityResourceId}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${deploymentStorage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: managedIdentityResourceId
          }
        }
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        // Host storage (AzureWebJobsStorage) via managed identity — the flex storage
        // accounts have shared-key access disabled by policy, so key-based auth is not possible.
        {
          name: 'AzureWebJobsStorage__accountName'
          value: deploymentStorage.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureWebJobsStorage__clientId'
          value: managedIdentityClientId
        }
        {
          name: 'AZURE_CLIENT_ID'
          value: managedIdentityClientId
        }
        // Service Bus trigger connection ("ServiceBus") used by the orchestrator's
        // serviceBusTrigger; identity-based, harmless on the API app.
        {
          name: 'ServiceBus__fullyQualifiedNamespace'
          value: serviceBusFqdn
        }
        {
          name: 'ServiceBus__credential'
          value: 'managedidentity'
        }
        {
          name: 'ServiceBus__clientId'
          value: managedIdentityClientId
        }
        // Application configuration (hierarchical keys bound by the .NET code).
        {
          name: 'AssetTerminator__Audit__BlobServiceUri'
          value: auditBlobServiceUri
        }
        {
          name: 'AssetTerminator__Messaging__FullyQualifiedNamespace'
          value: serviceBusFqdn
        }
        {
          name: 'AssetTerminator__Messaging__OrchestrationQueue'
          value: 'decommission-orchestration'
        }
        {
          name: 'AssetTerminator__Messaging__CloudActionsQueue'
          value: 'decommission-cloud'
        }
        {
          name: 'AssetTerminator__Messaging__OnPremActionsQueue'
          value: 'decommission-onprem'
        }
        {
          name: 'AssetTerminator__KeyVaultUri'
          value: keyVaultUri
        }
        {
          name: 'AssetTerminator__StateStore__ConnectionString'
          value: 'Server=tcp:${sqlServerFqdn},1433;Database=${sqlDatabaseName};Encrypt=True;TrustServerCertificate=False;Authentication=Active Directory Managed Identity;User Id=${managedIdentityClientId};'
        }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
  }
  dependsOn: [
    deploymentContainer
  ]
}

// If VNet integration is added later for Flex Consumption, delegate the subnet to Microsoft.App/environments, NOT Microsoft.Web/serverFarms.

output functionAppName string = functionApp.name
output functionAppId string = functionApp.id
output defaultHostName string = functionApp.properties.defaultHostName
