param location string
param tags object
param auditStorageName string
param apiDeploymentStorageName string
param orchestratorDeploymentStorageName string
param wormRetentionDays int = 2555

resource auditStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: auditStorageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_GRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource auditBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: auditStorage
  name: 'default'
  properties: {
    isVersioningEnabled: true
    changeFeed: {
      enabled: true
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 30
    }
  }
}

resource auditContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: auditBlobService
  name: 'audit'
  properties: {
    publicAccess: 'None'
    immutableStorageWithVersioning: {
      enabled: true
    }
  }
}

resource auditImmutabilityPolicy 'Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies@2023-05-01' = {
  parent: auditContainer
  name: 'default'
  properties: {
    immutabilityPeriodSinceCreationInDays: wormRetentionDays
    allowProtectedAppendWrites: true
  }
}

resource apiDeploymentStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: apiDeploymentStorageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource orchestratorDeploymentStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: orchestratorDeploymentStorageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

output auditStorageName string = auditStorage.name
output auditStorageId string = auditStorage.id
output auditBlobServiceUri string = auditStorage.properties.primaryEndpoints.blob
output auditContainerName string = auditContainer.name
output apiDeploymentStorageName string = apiDeploymentStorage.name
output orchestratorDeploymentStorageName string = orchestratorDeploymentStorage.name
