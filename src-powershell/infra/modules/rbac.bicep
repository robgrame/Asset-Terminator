param auditStorageName string
param serviceBusNamespaceName string
param auditPrincipalIds array
param serviceBusPrincipalIds array

@description('Function host (flex) storage accounts and the app principal that owns each: [{ storageName, principalId }]. Durable Functions requires blob+queue+table data access on the host storage.')
param hostStorageAssignments array

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
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

// Function host (flex) storage: Durable Functions + the runtime need blob (owner),
// queue and table data access. The flex storage accounts have shared-key access
// disabled, so the app authenticates with its managed identity.
resource hostStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = [for a in hostStorageAssignments: {
  name: a.storageName
}]

resource hostBlobOwnerAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (a, i) in hostStorageAssignments: {
  name: guid(hostStorage[i].id, a.principalId, storageBlobDataOwnerRoleId)
  scope: hostStorage[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: a.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource hostQueueContributorAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (a, i) in hostStorageAssignments: {
  name: guid(hostStorage[i].id, a.principalId, storageQueueDataContributorRoleId)
  scope: hostStorage[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
    principalId: a.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource hostTableContributorAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (a, i) in hostStorageAssignments: {
  name: guid(hostStorage[i].id, a.principalId, storageTableDataContributorRoleId)
  scope: hostStorage[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
    principalId: a.principalId
    principalType: 'ServicePrincipal'
  }
}]
