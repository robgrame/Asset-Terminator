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

$functionAppName = $outputs.functionAppName.value
$functionPrincipalId = $outputs.functionPrincipalId.value
Write-Host "    Function App        : $functionAppName"
Write-Host "    Identity principalId : $functionPrincipalId"
Write-Host "    Service Bus          : $($outputs.serviceBusNamespace.value) / $($outputs.queueName.value)"

# ---------------------------------------------------------------------------
# Grant Microsoft Graph application permissions to the Function App identity.
# These cannot be assigned via Bicep and require an Entra administrator.
# ---------------------------------------------------------------------------
if (-not $SkipGraphConsent) {
    Write-Host '==> Granting Microsoft Graph app roles to the Function App identity...' -ForegroundColor Cyan
    $graphAppId = '00000003-0000-0000-c000-000000000000'
    $graphSpId = az ad sp list --filter "appId eq '$graphAppId'" --query '[0].id' -o tsv

    $roleNames = @(
        'DeviceManagementManagedDevices.Read.All',                 # read managed device (guardrail signals)
        'DeviceManagementManagedDevices.PrivilegedOperations.All'  # wipe / retire
    )

    foreach ($roleName in $roleNames) {
        $roleId = az ad sp show --id $graphSpId --query "appRoles[?value=='$roleName' && contains(allowedMemberTypes, 'Application')].id | [0]" -o tsv
        if (-not $roleId) { Write-Warning "Role '$roleName' not found on Graph SP; skipping."; continue }

        $body = @{ principalId = $functionPrincipalId; resourceId = $graphSpId; appRoleId = $roleId } | ConvertTo-Json
        try {
            az rest --method POST `
                --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$functionPrincipalId/appRoleAssignments" `
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
    Write-Warning 'Skipping Graph consent. Assign DeviceManagementManagedDevices.Read.All and .PrivilegedOperations.All to the Function App identity manually.'
}

# ---------------------------------------------------------------------------
# Publish the PowerShell function code.
# ---------------------------------------------------------------------------
if (-not $SkipPublish) {
    Write-Host '==> Publishing function code...' -ForegroundColor Cyan
    Push-Location $projectRoot
    try {
        func azure functionapp publish $functionAppName --powershell
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Warning "Skipping publish. Run:  func azure functionapp publish $functionAppName --powershell"
}

Write-Host '==> Done.' -ForegroundColor Green
Write-Host "Test with:  POST https://$functionAppName.azurewebsites.net/api/v1/wipe?code=<function-key>" -ForegroundColor Green
