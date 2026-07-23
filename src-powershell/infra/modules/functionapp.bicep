// functionapp.bicep — PowerShell 7.4 Flex Consumption Function App.
// Parallel of infra/modules/functionapp.bicep (dotnet-isolated). The difference vs the .NET
// host is (1) runtime name/version = powershell/7.4 and (2) the app settings use the *flat*
// env-var names the AT.* PowerShell modules read (SQL_SERVER, SB_NAMESPACE, AUDIT_BLOB_ACCOUNT,
// UAMI_CLIENT_ID, ...) instead of the hierarchical AssetTerminator__* keys bound by the .NET code.
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
param auditStorageAccountName string
param auditContainerName string = 'audit'
param serviceBusFqdn string
param keyVaultUri string

@description('Timer cron for the reconciliation/polling function (NCRONTAB).')
param pollingCron string = '0 */5 * * * *'

@description('Orchestration queue name.')
param orchestrationQueue string = 'decommission-orchestration'
@description('Cloud actions queue name.')
param cloudQueue string = 'decommission-cloud'
@description('On-prem actions queue name.')
param onpremQueue string = 'decommission-onprem'

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
        name: 'powershell'
        version: '7.4'
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
        // Host storage (AzureWebJobsStorage) via managed identity — shared-key access is disabled.
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
        // Passwordless token acquisition: AT.Common\Get-IdentityToken selects this UAMI.
        {
          name: 'UAMI_CLIENT_ID'
          value: managedIdentityClientId
        }
        // Service Bus trigger connection ("ServiceBus") used by the orchestrator's WorkflowStart.
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
        // --- Flat settings consumed by the AT.* PowerShell modules ---
        // AT.Infrastructure\SqlStateStore: SQL_SERVER / SQL_DATABASE (token via MI).
        {
          name: 'SQL_SERVER'
          value: sqlServerFqdn
        }
        {
          name: 'SQL_DATABASE'
          value: sqlDatabaseName
        }
        // AT.Infrastructure\Messaging: SB_NAMESPACE + queue names.
        {
          name: 'SB_NAMESPACE'
          value: serviceBusFqdn
        }
        {
          name: 'SB_ORCHESTRATION_QUEUE'
          value: orchestrationQueue
        }
        {
          name: 'SB_CLOUD_QUEUE'
          value: cloudQueue
        }
        {
          name: 'SB_ONPREM_QUEUE'
          value: onpremQueue
        }
        // AT.Infrastructure\Audit: AUDIT_BLOB_ACCOUNT + AUDIT_CONTAINER (WORM hash-chain).
        {
          name: 'AUDIT_BLOB_ACCOUNT'
          value: auditStorageAccountName
        }
        {
          name: 'AUDIT_CONTAINER'
          value: auditContainerName
        }
        // AT.Infrastructure\Secrets: Key Vault URI.
        {
          name: 'AssetTerminator__KeyVaultUri'
          value: keyVaultUri
        }
        // Orchestration / reconciliation knobs read by the orchestrator run.ps1 files.
        {
          name: 'AssetTerminator__Orchestration__PollingCron'
          value: pollingCron
        }
        {
          name: 'AssetTerminator__Orchestration__PreWipePollIntervalSeconds'
          value: '300'
        }
        {
          name: 'AssetTerminator__Orchestration__RetryBaseDelaySeconds'
          value: '10'
        }
        {
          name: 'AssetTerminator__Orchestration__RetryMaxDelaySeconds'
          value: '3600'
        }
        {
          name: 'AssetTerminator__PreWipe__RequireCompletionBeforeWipe'
          value: 'true'
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

output functionAppName string = functionApp.name
output functionAppId string = functionApp.id
output defaultHostName string = functionApp.properties.defaultHostName
