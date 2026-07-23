[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroup,

    [string] $Location = 'westeurope',

    [string] $NamePrefix = 'astterm',

    [string] $Env = 'dev',

    [Parameter(Mandatory = $true)]
    [string] $SqlAdminGroupName,

    [Parameter(Mandatory = $true)]
    [string] $SqlAdminGroupObjectId,

    [int] $WormRetentionDays = 2555,

    [bool] $UseLocalAuth = $false,

    [bool] $DeployWorkbook = $true,

    [bool] $DeployGrafana = $false,

    [string] $GrafanaName = '',

    [string[]] $GrafanaAdminObjectIds = @()
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateFile = Join-Path $scriptRoot 'main.bicep'

Write-Host "Ensuring resource group '$ResourceGroup' exists in '$Location'..."
$groupExists = az group exists --name $ResourceGroup | ConvertFrom-Json
if (-not $groupExists) {
    az group create --name $ResourceGroup --location $Location --output none
}

$parameters = @(
    "namePrefix=$NamePrefix"
    "location=$Location"
    "env=$Env"
    "wormRetentionDays=$WormRetentionDays"
    "sqlAdminGroupName=$SqlAdminGroupName"
    "sqlAdminGroupObjectId=$SqlAdminGroupObjectId"
    "useLocalAuth=$($UseLocalAuth.ToString().ToLowerInvariant())"
    "deployWorkbook=$($DeployWorkbook.ToString().ToLowerInvariant())"
    "deployGrafana=$($DeployGrafana.ToString().ToLowerInvariant())"
    "grafanaName=$GrafanaName"
    "grafanaAdminObjectIds=$('[' + (($GrafanaAdminObjectIds | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']')"
)

Write-Host 'Running deployment what-if...'
az deployment group what-if `
    --resource-group $ResourceGroup `
    --template-file $templateFile `
    --parameters $parameters

Write-Host 'Creating deployment...'
$deploymentName = "asset-terminator-$Env-$(Get-Date -Format 'yyyyMMddHHmmss')"
$outputsJson = az deployment group create `
    --name $deploymentName `
    --resource-group $ResourceGroup `
    --template-file $templateFile `
    --parameters $parameters `
    --query properties.outputs `
    --output json

Write-Host 'Deployment outputs:'
$outputsJson | ConvertFrom-Json | ConvertTo-Json -Depth 20

<#
Microsoft Graph application permissions cannot be granted with Bicep. After deployment,
assign required Graph app roles to the orchestrator UAMI service principal, then grant admin consent.
Example permissions include:
- DeviceManagementManagedDevices.PrivilegedOperations.All
- DeviceManagementManagedDevices.ReadWrite.All
- Device.ReadWrite.All
- DeviceManagementServiceConfig.ReadWrite.All  (required to delete the device from Windows Autopilot)

$outputs = $outputsJson | ConvertFrom-Json
$orchestratorPrincipalId = $outputs.orchestratorUamiPrincipalId.value
$graphAppId = '00000003-0000-0000-c000-000000000000'
$graphSpId = az ad sp list --filter "appId eq '$graphAppId'" --query "[0].id" -o tsv
$roleNames = @(
    'DeviceManagementManagedDevices.PrivilegedOperations.All',
    'DeviceManagementManagedDevices.ReadWrite.All',
    'Device.ReadWrite.All',
    'DeviceManagementServiceConfig.ReadWrite.All'
)
foreach ($roleName in $roleNames) {
    $roleId = az ad sp show --id $graphSpId --query "appRoles[?value=='$roleName' && allowedMemberTypes[?@=='Application']].id | [0]" -o tsv
    az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$orchestratorPrincipalId/appRoleAssignments" --body @{
        principalId = $orchestratorPrincipalId
        resourceId  = $graphSpId
        appRoleId   = $roleId
    } | ConvertTo-Json
}

Post-deploy SQL contained users must be created by the Entra SQL admin group:

CREATE USER [<uami-api-name>] FROM EXTERNAL PROVIDER;
CREATE USER [<uami-orchestrator-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<uami-api-name>];
ALTER ROLE db_datawriter ADD MEMBER [<uami-api-name>];
ALTER ROLE db_datareader ADD MEMBER [<uami-orchestrator-name>];
ALTER ROLE db_datawriter ADD MEMBER [<uami-orchestrator-name>];
GRANT EXECUTE TO [<uami-api-name>];
GRANT EXECUTE TO [<uami-orchestrator-name>];

The application has no EF migration/EnsureCreated step, so the database schema must be
created once after the SQL server + database are provisioned. Generate the script from the
DbContext (ctx.Database.GenerateCreateScript()) and apply it against the database with an
Entra token, or run the equivalent DDL. Tables: DecommissionRequests (with DispositionType
nvarchar(32)), DecommissionActions, GuardrailOverrides.
#>
