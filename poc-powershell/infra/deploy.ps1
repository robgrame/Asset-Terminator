[CmdletBinding()]
param(
    [string] $ResourceGroup = 'ASSET-TERMINATOR-POC-RG',
    [string] $Location = 'northeurope',
    [string] $NamePrefix = 'attpoc',
    [string] $Env = 'dev',

    # Skip the Microsoft Graph app-role assignment step (requires an Entra admin).
    [switch] $SkipGraphConsent,

    # Skip publishing the function code (infra only).
    [switch] $SkipPublish
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$templateFile = Join-Path $scriptRoot 'main.bicep'

Write-Host "==> Ensuring resource group '$ResourceGroup' in '$Location'..." -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --output none

Write-Host '==> Deploying infrastructure...' -ForegroundColor Cyan
$deploymentName = "attpoc-$Env-$(Get-Date -Format 'yyyyMMddHHmmss')"
$outputs = az deployment group create `
    --name $deploymentName `
    --resource-group $ResourceGroup `
    --template-file $templateFile `
    --parameters namePrefix=$NamePrefix location=$Location env=$Env `
    --query properties.outputs --output json | ConvertFrom-Json

$intakeApp = $outputs.intakeFunctionAppName.value
$processorApp = $outputs.processorFunctionAppName.value
$processorPrincipalId = $outputs.processorPrincipalId.value

Write-Host "    Intake App           : $intakeApp (no Graph access)"
Write-Host "    Processor App        : $processorApp (Graph-privileged)"
Write-Host "    Processor principalId : $processorPrincipalId"
Write-Host "    Service Bus          : $($outputs.serviceBusNamespace.value) / $($outputs.queueName.value)"
Write-Host "    State store          : $($outputs.stateStorageAccount.value) / $($outputs.stateTableName.value)"

# ---------------------------------------------------------------------------
# Grant Microsoft Graph application permissions -- to the PROCESSOR identity
# only. The internet-facing intake app deliberately has no Graph access.
# These cannot be assigned via Bicep and require an Entra administrator.
# ---------------------------------------------------------------------------
if (-not $SkipGraphConsent) {
    Write-Host '==> Granting Microsoft Graph app roles to the Processor identity...' -ForegroundColor Cyan
    $graphAppId = '00000003-0000-0000-c000-000000000000'
    $graphSpId = az ad sp list --filter "appId eq '$graphAppId'" --query '[0].id' -o tsv

    $roleNames = @(
        'DeviceManagementManagedDevices.Read.All',                 # read managed device (guardrail signals)
        'DeviceManagementManagedDevices.PrivilegedOperations.All'  # wipe / retire
    )

    foreach ($roleName in $roleNames) {
        $roleId = az ad sp show --id $graphSpId --query "appRoles[?value=='$roleName' && contains(allowedMemberTypes, 'Application')].id | [0]" -o tsv
        if (-not $roleId) { Write-Warning "Role '$roleName' not found on Graph SP; skipping."; continue }

        $body = @{ principalId = $processorPrincipalId; resourceId = $graphSpId; appRoleId = $roleId } | ConvertTo-Json
        try {
            az rest --method POST `
                --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$processorPrincipalId/appRoleAssignments" `
                --headers 'Content-Type=application/json' `
                --body $body --output none
            Write-Host "    Granted: $roleName"
        }
        catch {
            Write-Warning "Could not grant '$roleName' (already assigned, or insufficient privileges): $($_.Exception.Message)"
        }
    }
}
else {
    Write-Warning 'Skipping Graph consent. Assign DeviceManagementManagedDevices.Read.All and .PrivilegedOperations.All to the PROCESSOR identity manually.'
}

# ---------------------------------------------------------------------------
# Publish the PowerShell function code -- each app from its own package folder.
# ---------------------------------------------------------------------------
function Publish-App {
    param([string] $AppName, [string] $FolderName)
    Write-Host "==> Publishing '$AppName' from '$FolderName'..." -ForegroundColor Cyan
    Push-Location (Join-Path $projectRoot $FolderName)
    try {
        func azure functionapp publish $AppName --powershell
    }
    finally {
        Pop-Location
    }
}

if (-not $SkipPublish) {
    Publish-App -AppName $intakeApp -FolderName 'intake'
    Publish-App -AppName $processorApp -FolderName 'processor'
}
else {
    Write-Warning "Skipping publish. Run:"
    Write-Warning "  cd intake;     func azure functionapp publish $intakeApp --powershell"
    Write-Warning "  cd processor;  func azure functionapp publish $processorApp --powershell"
}

Write-Host '==> Done.' -ForegroundColor Green
Write-Host "Submit : POST https://$intakeApp.azurewebsites.net/api/v1/wipe?code=<key>" -ForegroundColor Green
Write-Host "Status : GET  https://$intakeApp.azurewebsites.net/api/v1/decommission/{requestId}?code=<key>" -ForegroundColor Green
