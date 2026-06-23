param location string
param tags object
param appName string
param planName string
param deploymentStorageName string
param managedIdentityClientId string
param managedIdentityResourceId string
param appInsightsConnectionString string
param sqlServerFqdn string
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
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'AzureWebJobsStorage'
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
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'dotnet-isolated'
        }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${deploymentStorage.name};AccountKey=${deploymentStorage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'AZURE_CLIENT_ID'
          value: managedIdentityClientId
        }
        {
          name: 'SQL_SERVER_FQDN'
          value: sqlServerFqdn
        }
        {
          name: 'AUDIT_BLOB_SERVICE_URI'
          value: auditBlobServiceUri
        }
        {
          name: 'SERVICEBUS_FQDN'
          value: serviceBusFqdn
        }
        {
          name: 'KEYVAULT_URI'
          value: keyVaultUri
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
