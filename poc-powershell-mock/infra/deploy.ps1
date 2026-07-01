<#
.SYNOPSIS
    Deploys the Asset-Terminator PowerShell single-function mock.

.DESCRIPTION
    1. Provisions infrastructure with main.bicep (B1 Linux plan, Function App,
       storage, Application Insights).
    2. Publishes the Function App code (func azure functionapp publish).

    Microsoft Graph is called with an app registration + client secret. Provide
    the Graph credentials as parameters; they are written to Application Settings.

    Remember to grant the Graph app registration these APPLICATION permissions
    (admin consent required):
      - DeviceManagementManagedDevices.Read.All
      - DeviceManagementManagedDevices.PrivilegedOperations.All
      - DeviceManagementServiceConfig.ReadWrite.All

.EXAMPLE
    ./deploy.ps1 -ResourceGroup ASSET-TERMINATOR-RG -Location northeurope `
        -GraphTenantId <tenant> -GraphClientId <appId> -GraphClientSecret <secret>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $Location = 'northeurope',
    [string] $NamePrefix = 'attmock',
    [string] $Env = 'dev',

    [Parameter(Mandatory)] [string] $GraphTenantId,
    [Parameter(Mandatory)] [string] $GraphClientId,
    [Parameter(Mandatory)] [string] $GraphClientSecret,

    [switch] $SkipPublish
)

$ErrorActionPreference = 'Stop'
$infraDir = $PSScriptRoot
$root = Split-Path -Parent $infraDir

Write-Host "==> Ensuring resource group '$ResourceGroup' ($Location)" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --output none

Write-Host "==> Deploying infrastructure (main.bicep)" -ForegroundColor Cyan
$deployName = "attmock-$(Get-Date -Format yyyyMMddHHmmss)"
$outputs = az deployment group create `
    --name $deployName `
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

$functionAppName = $outputs.functionAppName.value
$hostName = $outputs.functionAppHostName.value
Write-Host "    Function App : $functionAppName" -ForegroundColor Green
Write-Host "    Host name    : $hostName" -ForegroundColor Green

if (-not $SkipPublish) {
    Write-Host "==> Publishing function code" -ForegroundColor Cyan
    Push-Location $root
    try {
        func azure functionapp publish $functionAppName --powershell
    }
    finally {
        Pop-Location
    }

    Write-Host "==> Retrieving function key" -ForegroundColor Cyan
    $key = az functionapp function keys list `
        --resource-group $ResourceGroup `
        --name $functionAppName `
        --function-name WipeDevice `
        --query default --output tsv 2>$null

    Write-Host ""
    Write-Host "Invoke with:" -ForegroundColor Yellow
    Write-Host "  POST https://$hostName/api/v1/wipe" -ForegroundColor Yellow
    if ($key) {
        Write-Host "  Header: x-functions-key: $key" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
