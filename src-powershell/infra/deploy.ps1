[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroup,

    [string] $Location = 'westeurope',

    [string] $NamePrefix = 'astterm',

    [string] $Env = 'psdev',

    [Parameter(Mandatory = $true)]
    [string] $SqlAdminGroupName,

    [Parameter(Mandatory = $true)]
    [string] $SqlAdminGroupObjectId,

    [int] $WormRetentionDays = 2555,

    [bool] $UseLocalAuth = $false,

    [string] $PollingCron = '0 */5 * * * *',

    [bool] $DeployWorkbook = $true,

    [bool] $DeployGrafana = $false,

    [string] $GrafanaName = '',

    [string[]] $GrafanaAdminObjectIds = @(),

    # Skip the `func azure functionapp publish` step (infra-only run).
    [switch] $SkipPublish
)

$ErrorActionPreference = 'Stop'
# Treat a non-zero exit code from az/func as a terminating error (PowerShell 7.4+).
$PSNativeCommandUseErrorActionPreference = $true

function Invoke-Native {
    <# Runs a native command and throws when it returns a non-zero exit code. #>
    param([Parameter(Mandatory)][scriptblock] $ScriptBlock, [string] $What = 'native command')
    & $ScriptBlock
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE." }
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcRoot = Split-Path -Parent $scriptRoot
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
    "pollingCron=$PollingCron"
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
$deploymentName = "asset-terminator-ps-$Env-$(Get-Date -Format 'yyyyMMddHHmmss')"
$outputsJson = az deployment group create `
    --name $deploymentName `
    --resource-group $ResourceGroup `
    --template-file $templateFile `
    --parameters $parameters `
    --query properties.outputs `
    --output json

$outputs = $outputsJson | ConvertFrom-Json
Write-Host 'Deployment outputs:'
$outputs | ConvertTo-Json -Depth 20

# --- Sync shared modules into each app's Modules/ folder (source of truth stays under modules/) ---
function Copy-AppModules {
    param([string] $AppDir, [string[]] $ModuleNames)
    $target = Join-Path $AppDir 'Modules'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    foreach ($m in $ModuleNames) {
        $srcMod = Join-Path $srcRoot "modules\$m"
        if (-not (Test-Path $srcMod)) {
            throw "Shared module '$m' not found at '$srcMod'; cannot sync into '$AppDir'."
        }
        # Clean sync: drop any stale copy so removed files don't linger in the app bundle.
        $dest = Join-Path $target $m
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Copy-Item $srcMod $dest -Recurse -Force
    }
}

if (-not $SkipPublish) {
    $apiApp = $outputs.apiFunctionAppName.value
    $orchApp = $outputs.orchestratorFunctionAppName.value

    $sharedForApi = @('AT.Common', 'AT.Contracts', 'AT.Core', 'AT.Infrastructure', 'AT.Guardrails')
    $sharedForOrch = @('AT.Common', 'AT.Contracts', 'AT.Core', 'AT.Infrastructure', 'AT.Guardrails',
        'AT.Providers.Intune', 'AT.Providers.EntraId')

    Write-Host "Syncing shared modules into api/ and orchestrator/ ..."
    Copy-AppModules -AppDir (Join-Path $srcRoot 'api') -ModuleNames $sharedForApi
    Copy-AppModules -AppDir (Join-Path $srcRoot 'orchestrator') -ModuleNames $sharedForOrch

    Write-Host "Publishing API Function App '$apiApp'..."
    Push-Location (Join-Path $srcRoot 'api')
    try { Invoke-Native { func azure functionapp publish $apiApp --powershell } "func publish '$apiApp'" } finally { Pop-Location }

    Write-Host "Publishing Orchestrator Function App '$orchApp'..."
    Push-Location (Join-Path $srcRoot 'orchestrator')
    try { Invoke-Native { func azure functionapp publish $orchApp --powershell } "func publish '$orchApp'" } finally { Pop-Location }
}

Write-Host ''
Write-Host 'Next manual steps (cannot be done in Bicep):'
Write-Host '  1. Apply the SQL schema (no EF migration): run infra/sql/schema.sql against the DB with an Entra token.'
Write-Host '  2. Create contained SQL users for the API / orchestrator / on-prem UAMIs (see comment block below).'
Write-Host '  3. Grant Microsoft Graph app roles to the orchestrator UAMI (Intune/Entra/Autopilot) and consent.'
Write-Host '  4. Deploy the on-prem agent as a SYSTEM scheduled task (onprem-agent/Install-OnPremAgent.ps1).'

<#
Post-deploy SQL contained users (run as the Entra SQL admin group against the database):

    CREATE USER [<uami-api-name>] FROM EXTERNAL PROVIDER;
    CREATE USER [<uami-orchestrator-name>] FROM EXTERNAL PROVIDER;
    CREATE USER [<uami-onprem-name>] FROM EXTERNAL PROVIDER;
    ALTER ROLE db_datareader ADD MEMBER [<uami-api-name>];
    ALTER ROLE db_datawriter ADD MEMBER [<uami-api-name>];
    ALTER ROLE db_datareader ADD MEMBER [<uami-orchestrator-name>];
    ALTER ROLE db_datawriter ADD MEMBER [<uami-orchestrator-name>];
    ALTER ROLE db_datareader ADD MEMBER [<uami-onprem-name>];
    ALTER ROLE db_datawriter ADD MEMBER [<uami-onprem-name>];

The on-prem agent updates action status directly in SQL, so its UAMI (or the identity the
scheduled task runs under, via Azure Arc / az CLI) needs db_datareader + db_datawriter as well.

Microsoft Graph application permissions cannot be granted with Bicep. Assign these app roles to
the orchestrator UAMI service principal ($outputs.orchestratorUamiPrincipalId.value) and grant
admin consent:
    - DeviceManagementManagedDevices.PrivilegedOperations.All
    - DeviceManagementManagedDevices.ReadWrite.All
    - Device.ReadWrite.All
    - DeviceManagementServiceConfig.ReadWrite.All   (required to delete from Windows Autopilot)
#>
