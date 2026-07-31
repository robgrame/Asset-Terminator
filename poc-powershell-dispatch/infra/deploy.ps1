<#
.SYNOPSIS
    Deploys the Asset-Terminator dispatch PoC (Service Bus + runbook dispatcher).

.DESCRIPTION
    1. Provisions the infrastructure with main.bicep: shared App Service plan,
       three Function Apps (api + worker + remote MCP) with dedicated
       user-assigned identities,
       a Service Bus namespace with the asset-disposal topic and one subscription
       per platform, an Automation Account, the state table and the private
       endpoints required by the subscription policy.
    2. Synchronises the shared PowerShell modules into the PowerShell apps.
    3. Builds the TypeScript MCP app and publishes all three Function Apps.

    Microsoft Graph is only used by the intake for read-only device lookups
    (resolve serial -> managedDevice, disambiguate the "Mobile" operating
    system). Provide an app registration with these APPLICATION permissions
    (admin consent required):
      - DeviceManagementManagedDevices.Read.All

    The runbooks themselves must be imported into the Automation Account and
    published separately - see ../README.md.

.EXAMPLE
    ./deploy.ps1 -ResourceGroup ASSET-TERMINATOR-DISPATCH-RG `
        -Subscription b45c5b53-d8f3-4a4c-9fe5-5537818a9886 `
        -Location westeurope `
        -GraphTenantId <tenant> -GraphClientId <appId> -GraphClientSecret <secret>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $Subscription,
    [string] $Location = 'westeurope',
    [string] $NamePrefix = 'attdisp',
    [string] $Env = 'dev',

    [Parameter(Mandatory)] [string] $GraphTenantId,
    [Parameter(Mandatory)] [string] $GraphClientId,
    [Parameter(Mandatory)] [string] $GraphClientSecret,

    [switch] $SkipPublish
)

$ErrorActionPreference = 'Stop'
$infraDir = $PSScriptRoot
$root = Split-Path -Parent $infraDir

if ($Subscription) {
    Write-Host "==> Selecting subscription '$Subscription'" -ForegroundColor Cyan
    az account set --subscription $Subscription
}
$subId = az account show --query id --output tsv
if (-not $subId) { throw 'Unable to resolve the current subscription. Run "az login" first.' }

Write-Host "==> Ensuring resource group '$ResourceGroup' ($Location)" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --subscription $subId --output none

Write-Host "==> Deploying infrastructure (main.bicep)" -ForegroundColor Cyan
$deployName = "attdisp-$(Get-Date -Format yyyyMMddHHmmss)"
$outputs = az deployment group create `
    --name $deployName `
    --subscription $subId `
    --resource-group $ResourceGroup `
    --template-file (Join-Path $infraDir 'main.bicep') `
    --parameters `
        namePrefix=$NamePrefix `
        location=$Location `
        env=$Env `
        graphTenantId=$GraphTenantId `
        graphClientId=$GraphClientId `
        graphClientSecret=$GraphClientSecret `
    --query properties.outputs `
    --output json | ConvertFrom-Json

if (-not $outputs) { throw 'Infrastructure deployment did not return any output.' }

$apiAppName = $outputs.apiAppName.value
$workerAppName = $outputs.workerAppName.value
$mcpAppName = $outputs.mcpAppName.value
$apiHostName = $outputs.apiAppHostName.value
$mcpHostName = $outputs.mcpAppHostName.value

Write-Host "    API Function App    : $apiAppName" -ForegroundColor Green
Write-Host "    Worker Function App : $workerAppName" -ForegroundColor Green
Write-Host "    MCP Function App    : $mcpAppName" -ForegroundColor Green
Write-Host "    Service Bus         : $($outputs.serviceBusNamespace.value)" -ForegroundColor Green
Write-Host "    Automation Account  : $($outputs.automationAccountName.value)" -ForegroundColor Green

Write-Host "==> Synchronising shared modules" -ForegroundColor Cyan
& (Join-Path $root 'build.ps1') -Clean

# --- Runbooks ---------------------------------------------------------------
# The Bicep template creates empty runbook shells; the PowerShell content is
# uploaded here so that a code change is not a template change.
$automationAccount = $outputs.automationAccountName.value
$runbookDir = Join-Path $root 'runbooks'
$runbookFiles = @{
    'RBK-WindowsDisposal' = 'RBK-WindowsDisposal.ps1'
    'RBK-AppleDisposal'   = 'RBK-AppleDisposal.ps1'
    'RBK-AndroidDisposal' = 'RBK-AndroidDisposal.ps1'
}

foreach ($runbookName in $runbookFiles.Keys) {
    $file = Join-Path $runbookDir $runbookFiles[$runbookName]
    if (-not (Test-Path $file)) { throw "Runbook file not found: $file" }

    Write-Host "==> Uploading runbook $runbookName" -ForegroundColor Cyan
    $draftUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$automationAccount/runbooks/$runbookName/draft/content?api-version=2023-11-01"

    az rest --method PUT --url $draftUri `
        --headers 'Content-Type=text/powershell' `
        --body "@$file" --output none
    if ($LASTEXITCODE -ne 0) { throw "Upload of runbook $runbookName failed." }

    az rest --method POST `
        --url "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$automationAccount/runbooks/$runbookName/publish?api-version=2023-11-01" `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "Publish of runbook $runbookName failed." }
}

Write-Host "    Runbooks published: $($runbookFiles.Count)" -ForegroundColor Green
Write-Host "    NOTE: the encrypted Automation variables (ClientSecret, Certificate_thumbprint, ABM-*, KME-*)" -ForegroundColor Yellow
Write-Host "          are created empty and must be populated as required before a non-dry-run wipe." -ForegroundColor Yellow

Write-Host "==> Configuring the MCP-to-API credential" -ForegroundColor Cyan
$apiHostKey = az functionapp keys list `
    --subscription $subId `
    --resource-group $ResourceGroup `
    --name $apiAppName `
    --query functionKeys.default `
    --output tsv
if ($LASTEXITCODE -ne 0 -or -not $apiHostKey) {
    throw "Unable to retrieve the default host key for $apiAppName."
}

az functionapp config appsettings set `
    --subscription $subId `
    --resource-group $ResourceGroup `
    --name $mcpAppName `
    --settings "AT_FUNCTION_KEY=$apiHostKey" `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw "Unable to configure AT_FUNCTION_KEY on $mcpAppName."
}

if ($SkipPublish) {
    Write-Host ""
    Write-Host "Publish skipped. Done." -ForegroundColor Green
    return
}

# NOTE: `func azure functionapp publish` resets the az CLI default subscription,
# so every az call after this point must pass --subscription explicitly.
foreach ($app in @(
        @{ Name = $apiAppName; Path = Join-Path $root 'api' },
        @{ Name = $workerAppName; Path = Join-Path $root 'worker' })) {

    Write-Host "==> Publishing $($app.Name)" -ForegroundColor Cyan
    Push-Location $app.Path
    try {
        func azure functionapp publish $app.Name --powershell
        if ($LASTEXITCODE -ne 0) { throw "Publish of $($app.Name) failed with exit code $LASTEXITCODE." }
    }
    finally {
        Pop-Location
    }
}

Write-Host "==> Building the Azure Functions MCP server" -ForegroundColor Cyan
$mcpPath = Join-Path $root 'mcp-server'
Push-Location $mcpPath
try {
    npm ci
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit code $LASTEXITCODE." }

    npm run build
    if ($LASTEXITCODE -ne 0) { throw "MCP build failed with exit code $LASTEXITCODE." }

    Write-Host "==> Publishing $mcpAppName" -ForegroundColor Cyan
    func azure functionapp publish $mcpAppName --typescript
    if ($LASTEXITCODE -ne 0) { throw "Publish of $mcpAppName failed with exit code $LASTEXITCODE." }
}
finally {
    Pop-Location
}

Write-Host "==> Retrieving the intake function key" -ForegroundColor Cyan
$key = az functionapp function keys list `
    --subscription $subId `
    --resource-group $ResourceGroup `
    --name $apiAppName `
    --function-name WipeIntake `
    --query default --output tsv 2>$null

Write-Host ""
Write-Host "Submit a disposal request with:" -ForegroundColor Yellow
Write-Host "  POST https://$apiHostName/api/v1/wipe" -ForegroundColor Yellow
if ($key) {
    Write-Host "  Header: x-functions-key: $key" -ForegroundColor Yellow
}
Write-Host "  Body  : see ../samples/request-windows.json" -ForegroundColor Yellow
Write-Host ""
Write-Host "Remote MCP server:" -ForegroundColor Yellow
Write-Host "  URL   : https://$mcpHostName/runtime/webhooks/mcp" -ForegroundColor Yellow
Write-Host "  Key   : az functionapp keys list -g $ResourceGroup -n $mcpAppName --subscription $subId --query systemKeys.mcp_extension -o tsv" -ForegroundColor Yellow
Write-Host "  Header: x-functions-key: <mcp_extension-system-key>" -ForegroundColor Yellow
Write-Host ""
Write-Host "Done." -ForegroundColor Green
