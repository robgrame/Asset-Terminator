// Simplified public-endpoint deployment for Asset-Terminator Dispatch.
//
// This wrapper deploys the same application resources as main.bicep while
// explicitly disabling VNet integration, private endpoints and private DNS
// zones. Storage remains protected by managed identity/RBAC; only its network
// endpoint is public.

@description('Short resource name prefix.')
param namePrefix string = 'attdisp'

@description('Deployment location.')
param location string = resourceGroup().location

@description('Environment suffix.')
param env string = 'dev'

@description('Entra tenant (directory) ID for the Graph app registration.')
param graphTenantId string

@description('Application (client) ID of the Graph app registration.')
param graphClientId string

@description('Client secret of the Graph app registration.')
@secure()
param graphClientSecret string

@description('Microsoft.Graph.Authentication package version installed in the Automation Runtime Environment.')
param graphAuthenticationModuleVersion string = '2.39.0'

@description('PowerShell version used by Azure Automation runbooks and the Function App.')
param powerShellVersion string = '7.6'

module dispatch 'main.bicep' = {
  name: 'asset-terminator-public'
  params: {
    namePrefix: namePrefix
    location: location
    env: env
    graphTenantId: graphTenantId
    graphClientId: graphClientId
    graphClientSecret: graphClientSecret
    graphAuthenticationModuleVersion: graphAuthenticationModuleVersion
    powerShellVersion: powerShellVersion
    usePrivateEndpoints: false
  }
}

output apiAppName string = dispatch.outputs.apiAppName
output apiAppHostName string = dispatch.outputs.apiAppHostName
output automationAccountName string = dispatch.outputs.automationAccountName
output stateTableName string = dispatch.outputs.stateTableName
output apiIdentityClientId string = dispatch.outputs.apiIdentityClientId
