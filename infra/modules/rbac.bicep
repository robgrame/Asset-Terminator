param auditStorageName string
param serviceBusNamespaceName string
param auditPrincipalIds array
param serviceBusPrincipalIds array

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var serviceBusDataSenderRoleId = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
var serviceBusDataReceiverRoleId = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'

resource auditStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: auditStorageName
}

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2024-01-01' existing = {
  name: serviceBusNamespaceName
}

resource blobContributorAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in auditPrincipalIds: {
  name: guid(auditStorage.id, principalId, storageBlobDataContributorRoleId)
  scope: auditStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}]

resource serviceBusSenderAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in serviceBusPrincipalIds: {
  name: guid(serviceBusNamespace.id, principalId, serviceBusDataSenderRoleId)
  scope: serviceBusNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceBusDataSenderRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}]

resource serviceBusReceiverAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in serviceBusPrincipalIds: {
  name: guid(serviceBusNamespace.id, principalId, serviceBusDataReceiverRoleId)
  scope: serviceBusNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceBusDataReceiverRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}]
