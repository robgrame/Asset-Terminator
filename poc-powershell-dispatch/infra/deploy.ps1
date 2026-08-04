#Requires -Version 7.6

<#
.SYNOPSIS
    Deploys the Asset-Terminator dispatch PoC (Service Bus + runbook dispatcher).

.DESCRIPTION
    1. Provisions the infrastructure with main.bicep (or main-public.bicep when
       -PublicEndpoints is specified): shared App Service plan,
       two Function Apps (api + worker) with dedicated user-assigned identities,
       a Service Bus namespace with the asset-disposal topic and one subscription
       per platform, an Automation Account and the state table. The default
       template includes private connectivity; the public variant omits it.
    2. Generates and verifies self-contained Function scripts (build.ps1).
    3. Publishes both Function Apps.

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
    [string] $GraphAuthenticationModuleVersion = '2.39.0',
    [ValidatePattern('^7\.\d+$')] [string] $PowerShellVersion = '7.6',

    [switch] $PublicEndpoints,
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

$templateName = if ($PublicEndpoints) { 'main-public.bicep' } else { 'main.bicep' }
$templatePath = Join-Path $infraDir $templateName
Write-Host "==> Deploying infrastructure ($templateName)" -ForegroundColor Cyan
$deployName = "attdisp-$(Get-Date -Format yyyyMMddHHmmss)"
$outputs = az deployment group create `
    --name $deployName `
    --subscription $subId `
    --resource-group $ResourceGroup `
    --template-file $templatePath `
    --parameters `
        namePrefix=$NamePrefix `
        location=$Location `
        env=$Env `
        graphTenantId=$GraphTenantId `
        graphClientId=$GraphClientId `
        graphClientSecret=$GraphClientSecret `
        graphAuthenticationModuleVersion=$GraphAuthenticationModuleVersion `
        powerShellVersion=$PowerShellVersion `
    --query properties.outputs `
    --output json | ConvertFrom-Json

if (-not $outputs) { throw 'Infrastructure deployment did not return any output.' }

$apiAppName = $outputs.apiAppName.value
$workerAppName = $outputs.workerAppName.value
$apiHostName = $outputs.apiAppHostName.value

Write-Host "    API Function App    : $apiAppName" -ForegroundColor Green
Write-Host "    Worker Function App : $workerAppName" -ForegroundColor Green
Write-Host "    Service Bus         : $($outputs.serviceBusNamespace.value)" -ForegroundColor Green
Write-Host "    Automation Account  : $($outputs.automationAccountName.value)" -ForegroundColor Green

Write-Host "==> Generating self-contained Function scripts" -ForegroundColor Cyan
& (Join-Path $root 'build.ps1') -Clean

$functionApps = @(
    @{ Name = $apiAppName; Path = Join-Path $root 'api'; ExpectedFunctions = 2 },
    @{ Name = $workerAppName; Path = Join-Path $root 'worker'; ExpectedFunctions = 4 }
)

foreach ($app in $functionApps) {
    $runScripts = @(Get-ChildItem -Path $app.Path -Filter 'run.ps1' -Recurse -File)
    if ($runScripts.Count -ne $app.ExpectedFunctions) {
        throw "Expected $($app.ExpectedFunctions) generated run.ps1 files under $($app.Path), found $($runScripts.Count)."
    }

    $funcIgnore = Get-Content (Join-Path $app.Path '.funcignore') -Raw
    if ($funcIgnore -notmatch '(?m)^\*\*/handler\.ps1\s*$') {
        throw "The publish package for $($app.Name) does not exclude handler.ps1."
    }

    foreach ($runScript in $runScripts) {
        $source = Get-Content $runScript.FullName -Raw
        if ($source -notmatch '(?m)^# GENERATED FILE - DO NOT EDIT DIRECTLY\.\r?$' -or
            $source -notmatch '(?m)^# region Embedded module: AT\.[A-Za-z]+\.psm1\r?$') {
            throw "Function script is not a generated embedded artifact: $($runScript.FullName)"
        }
        if ($source -match '(?m)^[ \t]*Import-Module[^\r\n]*(?:\.\./)+Modules/AT\.[A-Za-z]+\.psm1') {
            throw "Function script still imports an external AT module: $($runScript.FullName)"
        }
    }
}
Write-Host "    Embedded Function scripts verified: $((($functionApps | ForEach-Object { $_.ExpectedFunctions }) | Measure-Object -Sum).Sum)" -ForegroundColor Green

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

if ($SkipPublish) {
    Write-Host ""
    Write-Host "Publish skipped. Done." -ForegroundColor Green
    return
}

# NOTE: `func azure functionapp publish` resets the az CLI default subscription,
# so every az call after this point must pass --subscription explicitly.
foreach ($app in $functionApps) {

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

Write-Host "==> Retrieving the default host key" -ForegroundColor Cyan
$key = az functionapp keys list `
    --subscription $subId `
    --resource-group $ResourceGroup `
    --name $apiAppName `
    --query functionKeys.default --output tsv 2>$null

Write-Host ""
Write-Host "Submit a disposal request with:" -ForegroundColor Yellow
Write-Host "  POST https://$apiHostName/api/v1/wipe" -ForegroundColor Yellow
if ($key) {
    Write-Host "  Header: x-functions-key: $key" -ForegroundColor Yellow
}
Write-Host "  Body  : see ../samples/request-windows.json" -ForegroundColor Yellow
Write-Host ""
Write-Host "Remember to import and publish the platform runbooks into '$($outputs.automationAccountName.value)'." -ForegroundColor Yellow
Write-Host ""
Write-Host "Done." -ForegroundColor Green
