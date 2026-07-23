targetScope = 'resourceGroup'

@description('Short resource name prefix.')
param namePrefix string = 'astterm'

@description('Deployment location.')
param location string = resourceGroup().location

@description('Environment suffix.')
param env string = 'dev'

@description('WORM immutability retention in days for the audit container.')
param wormRetentionDays int = 2555

@description('Display name of the Microsoft Entra group used as Azure SQL administrator.')
param sqlAdminGroupName string

@description('Object ID of the Microsoft Entra group used as Azure SQL administrator.')
param sqlAdminGroupObjectId string

@description('Set true to keep Service Bus SAS/local auth enabled for a simple on-premises agent bootstrap.')
param useLocalAuth bool = false

@description('Deploy the Azure Monitor Workbook with operational KPI/SLA tiles.')
param deployWorkbook bool = true

@description('Deploy an Azure Managed Grafana instance wired to Azure Monitor.')
param deployGrafana bool = false

@description('Grafana instance name. When empty a name is derived from the Log Analytics name.')
param grafanaName string = ''

@description('Entra object IDs (users or groups) granted the Grafana Admin role on the instance.')
param grafanaAdminObjectIds array = []

var tags = {
  solution: 'Asset-Terminator'
  env: env
}

var uniqueSuffix = uniqueString(resourceGroup().id, namePrefix, env)
var storagePrefix = toLower(replace(namePrefix, '-', ''))
var storageEnv = toLower(replace(env, '-', ''))

var logAnalyticsName = '${namePrefix}-law-${env}'
var appInsightsName = '${namePrefix}-appi-${env}'
var apiIdentityName = '${namePrefix}-uami-api-${env}'
var orchestratorIdentityName = '${namePrefix}-uami-orchestrator-${env}'
var onpremIdentityName = '${namePrefix}-uami-onprem-${env}'
var sqlServerName = '${namePrefix}-sql-${env}'
var sqlDatabaseName = '${namePrefix}-db-${env}'
var auditStorageName = take('${storagePrefix}audit${storageEnv}${uniqueSuffix}', 24)
var apiDeploymentStorageName = take('${storagePrefix}apiflex${storageEnv}${uniqueSuffix}', 24)
var orchestratorDeploymentStorageName = take('${storagePrefix}orchflex${storageEnv}${uniqueSuffix}', 24)
var keyVaultName = take('${namePrefix}-kv-${env}', 24)
var serviceBusNamespaceName = '${namePrefix}-sb-${env}'
var apiFunctionName = '${namePrefix}-func-api-${env}'
var orchestratorFunctionName = '${namePrefix}-func-orchestrator-${env}'
var apiPlanName = '${namePrefix}-plan-api-${env}'
var orchestratorPlanName = '${namePrefix}-plan-orchestrator-${env}'

module monitoring './modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    tags: tags
    logAnalyticsName: logAnalyticsName
    appInsightsName: appInsightsName
    deployWorkbook: deployWorkbook
    deployGrafana: deployGrafana
    grafanaName: grafanaName
    grafanaAdminObjectIds: grafanaAdminObjectIds
  }
}

module identity './modules/identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    tags: tags
    apiIdentityName: apiIdentityName
    orchestratorIdentityName: orchestratorIdentityName
    onpremIdentityName: onpremIdentityName
  }
}

module sql './modules/sql.bicep' = {
  name: 'sql'
  params: {
    location: location
    tags: tags
    serverName: sqlServerName
    databaseName: sqlDatabaseName
    sqlAdminGroupName: sqlAdminGroupName
    sqlAdminGroupObjectId: sqlAdminGroupObjectId
  }
}

module storage './modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    tags: tags
    auditStorageName: auditStorageName
    apiDeploymentStorageName: apiDeploymentStorageName
    orchestratorDeploymentStorageName: orchestratorDeploymentStorageName
    wormRetentionDays: wormRetentionDays
  }
}

module serviceBus './modules/servicebus.bicep' = {
  name: 'servicebus'
  params: {
    location: location
    tags: tags
    namespaceName: serviceBusNamespaceName
    useLocalAuth: useLocalAuth
  }
}

module keyVault './modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location: location
    tags: tags
    keyVaultName: keyVaultName
    principalIds: [
      identity.outputs.apiPrincipalId
      identity.outputs.orchestratorPrincipalId
      identity.outputs.onpremPrincipalId
    ]
  }
}

module rbac './modules/rbac.bicep' = {
  name: 'rbac'
  params: {
    auditStorageName: storage.outputs.auditStorageName
    serviceBusNamespaceName: serviceBus.outputs.namespaceName
    auditPrincipalIds: [
      identity.outputs.apiPrincipalId
      identity.outputs.orchestratorPrincipalId
    ]
    serviceBusPrincipalIds: [
      identity.outputs.apiPrincipalId
      identity.outputs.orchestratorPrincipalId
      identity.outputs.onpremPrincipalId
    ]
    hostStorageAssignments: [
      {
        storageName: storage.outputs.apiDeploymentStorageName
        principalId: identity.outputs.apiPrincipalId
      }
      {
        storageName: storage.outputs.orchestratorDeploymentStorageName
        principalId: identity.outputs.orchestratorPrincipalId
      }
    ]
  }
}

module apiFunction './modules/functionapp.bicep' = {
  name: 'func-api'
  params: {
    location: location
    tags: tags
    appName: apiFunctionName
    planName: apiPlanName
    deploymentStorageName: storage.outputs.apiDeploymentStorageName
    managedIdentityClientId: identity.outputs.apiClientId
    managedIdentityResourceId: identity.outputs.apiResourceId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    sqlServerFqdn: sql.outputs.serverFqdn
    sqlDatabaseName: sqlDatabaseName
    auditBlobServiceUri: storage.outputs.auditBlobServiceUri
    serviceBusFqdn: serviceBus.outputs.namespaceFqdn
    keyVaultUri: keyVault.outputs.keyVaultUri
  }
}

module orchestratorFunction './modules/functionapp.bicep' = {
  name: 'func-orchestrator'
  params: {
    location: location
    tags: tags
    appName: orchestratorFunctionName
    planName: orchestratorPlanName
    deploymentStorageName: storage.outputs.orchestratorDeploymentStorageName
    managedIdentityClientId: identity.outputs.orchestratorClientId
    managedIdentityResourceId: identity.outputs.orchestratorResourceId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    sqlServerFqdn: sql.outputs.serverFqdn
    sqlDatabaseName: sqlDatabaseName
    auditBlobServiceUri: storage.outputs.auditBlobServiceUri
    serviceBusFqdn: serviceBus.outputs.namespaceFqdn
    keyVaultUri: keyVault.outputs.keyVaultUri
  }
}

output apiFunctionAppName string = apiFunction.outputs.functionAppName
output orchestratorFunctionAppName string = orchestratorFunction.outputs.functionAppName
output sqlServerFqdn string = sql.outputs.serverFqdn
output auditBlobServiceUri string = storage.outputs.auditBlobServiceUri
output serviceBusFqdn string = serviceBus.outputs.namespaceFqdn
output keyVaultUri string = keyVault.outputs.keyVaultUri
output apiUamiClientId string = identity.outputs.apiClientId
output apiUamiPrincipalId string = identity.outputs.apiPrincipalId
output apiUamiResourceId string = identity.outputs.apiResourceId
output orchestratorUamiClientId string = identity.outputs.orchestratorClientId
output orchestratorUamiPrincipalId string = identity.outputs.orchestratorPrincipalId
output orchestratorUamiResourceId string = identity.outputs.orchestratorResourceId
output onpremUamiClientId string = identity.outputs.onpremClientId
output onpremUamiPrincipalId string = identity.outputs.onpremPrincipalId
output onpremUamiResourceId string = identity.outputs.onpremResourceId
output workbookResourceId string = monitoring.outputs.workbookResourceId
output grafanaEndpoint string = monitoring.outputs.grafanaEndpoint
