param location string
param tags object
param serverName string
param databaseName string
param sqlAdminGroupName string
param sqlAdminGroupObjectId string

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = {
  name: serverName
  location: location
  tags: tags
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'Group'
      login: sqlAdminGroupName
      sid: sqlAdminGroupObjectId
      tenantId: tenant().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: sqlServer
  name: databaseName
  location: location
  tags: tags
  sku: {
    name: 'GP_S_Gen5_2'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    autoPauseDelay: 60
    minCapacity: json('0.5')
    zoneRedundant: false
    readScale: 'Disabled'
  }
}

// TODO post-deploy: create contained database users for the API and orchestrator UAMIs, then grant only required roles.
// Sample T-SQL, run as the configured Entra SQL admin group:
// CREATE USER [uami-api-name] FROM EXTERNAL PROVIDER;
// CREATE USER [uami-orchestrator-name] FROM EXTERNAL PROVIDER;
// ALTER ROLE db_datareader ADD MEMBER [uami-api-name];
// ALTER ROLE db_datawriter ADD MEMBER [uami-api-name];
// ALTER ROLE db_datareader ADD MEMBER [uami-orchestrator-name];
// ALTER ROLE db_datawriter ADD MEMBER [uami-orchestrator-name];
// GRANT EXECUTE TO [uami-api-name];
// GRANT EXECUTE TO [uami-orchestrator-name];

output serverName string = sqlServer.name
output serverFqdn string = sqlServer.properties.fullyQualifiedDomainName
output databaseName string = database.name
output databaseId string = database.id
