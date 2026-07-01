using namespace System.Net

# WipeDevice - single HTTP-triggered function (mock).
#
# Combines the intake and the processing of a ServiceNow decommission request in
# ONE synchronous function:
#   1. Authenticates the caller with a Function API Key (authLevel = "function";
#      key passed as the x-functions-key header or ?code= query string). No
#      certificate is required.
#   2. Reads the request, including the operating system type sent by ServiceNow
#      (operatingSystem: Windows | Mac | Mobile).
#   3. Resolves the Intune managed device.
#   4. For Windows devices ONLY, deletes the device from Windows Autopilot first.
#   5. Issues the Intune wipe.
#
# Microsoft Graph is called with an app registration + client secret
# (GRAPH_TENANT_ID / GRAPH_CLIENT_ID / GRAPH_CLIENT_SECRET) - see Modules/Graph.psm1.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/Graph.psm1" -Force

function Write-Json {
    param([int] $StatusCode, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = ($Object | ConvertTo-Json -Depth 8)
    })
}

# The PowerShell worker may surface the body as a parsed object or a raw string.
$payload = $Request.Body
if ($payload -is [string]) {
    try { $payload = $payload | ConvertFrom-Json } catch { $payload = $null }
}

# --- Validation -------------------------------------------------------------
if (-not $payload) {
    Write-Json -StatusCode 400 -Object @{ error = 'Request body must be valid JSON.' }
    return
}

if (-not $payload.managedDeviceId -and -not $payload.deviceName -and -not $payload.serialNumber) {
    Write-Json -StatusCode 400 -Object @{ error = 'At least one of managedDeviceId, deviceName or serialNumber is required.' }
    return
}

$os = ConvertTo-DeviceOs -OperatingSystem ([string]$payload.operatingSystem)
if (-not $os) {
    Write-Json -StatusCode 400 -Object @{ error = "operatingSystem is required and must be one of: Windows, Mac, Mobile (aliases: win/macos/osx/ios/ipados/android/mobile)." }
    return
}

$correlationId = [guid]::NewGuid().ToString()
$requestId = if ($payload.requestId) { [string]$payload.requestId } else { $correlationId }

# DryRun: default from DEFAULT_DRY_RUN app setting (default false = execute for real).
$dryRun = Get-AppSettingBool -Name 'DEFAULT_DRY_RUN' -Default $false
if ($null -ne $payload.dryRun) { $dryRun = [System.Convert]::ToBoolean($payload.dryRun) }

$logProps = @{
    correlationId   = $correlationId
    requestId       = $requestId
    managedDeviceId = [string]$payload.managedDeviceId
    deviceName      = [string]$payload.deviceName
    serialNumber    = [string]$payload.serialNumber
    operatingSystem = $os
    dryRun          = $dryRun
}

Write-MockLog -Level 'Information' -Message 'Wipe request received.' -Properties $logProps

# --- Resolve the Intune managed device --------------------------------------
$device = $null
try {
    $device = Get-IntuneManagedDevice `
        -ManagedDeviceId ([string]$payload.managedDeviceId) `
        -DeviceName ([string]$payload.deviceName) `
        -SerialNumber ([string]$payload.serialNumber) `
        -LogProperties $logProps
}
catch {
    Write-MockLog -Level 'Error' -Message "Device lookup failed: $($_.Exception.Message)" -Properties $logProps
    Write-Json -StatusCode 502 -Object @{ error = 'Failed to query Microsoft Graph for the device.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

if (-not $device) {
    Write-MockLog -Level 'Warning' -Message 'Managed device not found in Intune.' -Properties $logProps
    Write-Json -StatusCode 404 -Object @{ error = 'Managed device not found in Intune.'; requestId = $requestId; correlationId = $correlationId }
    return
}

# Serial number for the Autopilot lookup: prefer the request, fall back to the device.
$serialForAutopilot = if ($payload.serialNumber) { [string]$payload.serialNumber } else { [string]$device.serialNumber }

$actions = [System.Collections.Generic.List[object]]::new()

# --- Windows-only: delete from Autopilot BEFORE the wipe --------------------
if ($os -eq 'Windows') {
    try {
        $ap = Remove-AutopilotDevice -SerialNumber $serialForAutopilot -DryRun:$dryRun -LogProperties $logProps
        $actions.Add($ap)
    }
    catch {
        Write-MockLog -Level 'Error' -Message "Autopilot delete failed: $($_.Exception.Message)" -Properties $logProps
        $actions.Add([pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'Error'; Detail = $_.Exception.Message })
    }
}
else {
    $actions.Add([pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'Skipped'; Detail = "Not a Windows device (operatingSystem = $os)." })
}

# --- Intune wipe ------------------------------------------------------------
$wipeFailed = $false
try {
    $wipe = Invoke-IntuneWipe -ManagedDeviceId $device.id -DryRun:$dryRun -LogProperties $logProps
    $actions.Add($wipe)
}
catch {
    $wipeFailed = $true
    Write-MockLog -Level 'Error' -Message "Wipe failed: $($_.Exception.Message)" -Properties $logProps
    $actions.Add([pscustomobject]@{ Action = 'Wipe'; Outcome = 'Error'; Detail = $_.Exception.Message })
}

$overall = if ($wipeFailed) { 'Failed' } elseif ($dryRun) { 'DryRun' } else { 'Completed' }
$statusCode = if ($wipeFailed) { 502 } else { 200 }

Write-MockLog -Level 'Information' -Message "Wipe request finished with status $overall." -Properties $logProps

Write-Json -StatusCode $statusCode -Object @{
    requestId       = $requestId
    correlationId   = $correlationId
    overallStatus   = $overall
    operatingSystem = $os
    dryRun          = $dryRun
    device          = @{
        id           = $device.id
        deviceName   = $device.deviceName
        serialNumber = $device.serialNumber
        os           = $device.operatingSystem
    }
    actions         = $actions
}
