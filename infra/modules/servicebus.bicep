param location string
param tags object
param namespaceName string
param useLocalAuth bool = false

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: namespaceName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    disableLocalAuth: !useLocalAuth
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

var queueNames = [
  'decommission-orchestration'
  'decommission-cloud'
  'decommission-onprem'
  'callback-deadletter'
]

resource queues 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = [for queueName in queueNames: {
  parent: serviceBusNamespace
  name: queueName
  properties: {
    lockDuration: 'PT1M'
    maxDeliveryCount: 10
    deadLetteringOnMessageExpiration: true
    defaultMessageTimeToLive: 'P14D'
    enablePartitioning: false
    requiresDuplicateDetection: false
  }
}]

// useLocalAuth=false disables SAS keys and favors managed identity. Set useLocalAuth=true only if the on-prem agent cannot use Entra ID yet.

output namespaceId string = serviceBusNamespace.id
output namespaceName string = serviceBusNamespace.name
output namespaceFqdn string = '${serviceBusNamespace.name}.servicebus.windows.net'
output queueNames array = queueNames
