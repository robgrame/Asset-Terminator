param location string
param tags object
param apiIdentityName string
param orchestratorIdentityName string
param onpremIdentityName string

resource apiIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: apiIdentityName
  location: location
  tags: tags
}

resource orchestratorIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: orchestratorIdentityName
  location: location
  tags: tags
}

resource onpremIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: onpremIdentityName
  location: location
  tags: tags
}

output apiClientId string = apiIdentity.properties.clientId
output apiPrincipalId string = apiIdentity.properties.principalId
output apiResourceId string = apiIdentity.id

output orchestratorClientId string = orchestratorIdentity.properties.clientId
output orchestratorPrincipalId string = orchestratorIdentity.properties.principalId
output orchestratorResourceId string = orchestratorIdentity.id

output onpremClientId string = onpremIdentity.properties.clientId
output onpremPrincipalId string = onpremIdentity.properties.principalId
output onpremResourceId string = onpremIdentity.id
