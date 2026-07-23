param location string
param tags object
param logAnalyticsName string
param appInsightsName string

@description('Deploy the Azure Monitor Workbook with operational KPI/SLA tiles.')
param deployWorkbook bool = true

@description('Deploy an Azure Managed Grafana instance wired to Azure Monitor.')
param deployGrafana bool = false

@description('Grafana SKU tier.')
@allowed([
  'Standard'
  'Essential'
])
param grafanaSku string = 'Standard'

@description('Grafana instance name. When empty a name is derived from logAnalyticsName. Must be 2-23 chars, unique in the resource group.')
param grafanaName string = ''

@description('Entra object IDs (users or groups) granted the Grafana Admin role on the instance.')
param grafanaAdminObjectIds array = []

// Built-in role definition IDs.
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var grafanaAdminRoleId = '22926164-76b3-42b3-bc55-97df8dab3e41'

var effectiveGrafanaName = empty(grafanaName) ? take('${replace(logAnalyticsName, '_', '-')}-graf', 23) : grafanaName

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Azure Monitor Workbook: operational KPI / SLA / drill-down tiles backed by the custom tables.
resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = if (deployWorkbook) {
  name: guid(workspace.id, 'decommission-operations')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'Asset-Terminator - Operations'
    category: 'workbook'
    sourceId: workspace.id
    version: '1.0'
    serializedData: replace(loadTextContent('./decommission-workbook.json'), '{LogAnalyticsResourceId}', workspace.id)
  }
}

// Azure Managed Grafana: shareable dashboards over Azure Monitor / Log Analytics.
resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' = if (deployGrafana) {
  name: effectiveGrafanaName
  location: location
  tags: tags
  sku: {
    name: grafanaSku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    apiKey: 'Disabled'
    deterministicOutboundIP: 'Disabled'
    grafanaIntegrations: {
      azureMonitorWorkspaceIntegrations: []
    }
  }
}

// Grafana managed identity must read Azure Monitor / Log Analytics in this resource group.
resource grafanaMonitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployGrafana) {
  name: guid(resourceGroup().id, effectiveGrafanaName, monitoringReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleId)
    principalId: grafana!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Human admins for the Grafana instance.
resource grafanaAdmins 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for oid in grafanaAdminObjectIds: if (deployGrafana) {
  name: guid(effectiveGrafanaName, oid, grafanaAdminRoleId)
  scope: grafana
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', grafanaAdminRoleId)
    principalId: oid
  }
}]

output workspaceId string = workspace.id
output appInsightsId string = appInsights.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
output workbookResourceId string = deployWorkbook ? workbook.id : ''
output grafanaEndpoint string = deployGrafana ? grafana!.properties.endpoint : ''
output grafanaResourceId string = deployGrafana ? grafana!.id : ''