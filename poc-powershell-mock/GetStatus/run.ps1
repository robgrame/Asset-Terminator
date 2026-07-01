using namespace System.Net

# GetStatus - HTTP-triggered read-only status endpoint (mock, option 1).
#
# Because the mock keeps NO local state, the request status is derived LIVE from
# Microsoft Graph every time it is queried:
#   * Intune wipe progress  -> managedDevices/{id}.deviceActionResults ('wipe').
#   * Autopilot removal      -> presence of a windowsAutopilotDeviceIdentities
#                               object for the serial (Windows only).
#
# Auth: Function API Key (authLevel = "function"; x-functions-key header or ?code=).
# Method: GET  /api/v1/wipe/status
# Query parameters (at least one identifier required):
#   managedDeviceId | deviceName | serialNumber   (device lookup)
#   operatingSystem                               (optional; enables Autopilot check for Windows)

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

$q = $Request.Query
$managedDeviceId = [string]$q.managedDeviceId
$deviceName      = [string]$q.deviceName
$serialNumber    = [string]$q.serialNumber
$osRaw           = [string]$q.operatingSystem

if (-not $managedDeviceId -and -not $deviceName -and -not $serialNumber) {
    Write-Json -StatusCode 400 -Object @{ error = 'At least one of managedDeviceId, deviceName or serialNumber is required (query string).' }
    return
}

$correlationId = [guid]::NewGuid().ToString()
$os = ConvertTo-DeviceOs -OperatingSystem $osRaw

$logProps = @{
    correlationId   = $correlationId
    managedDeviceId = $managedDeviceId
    deviceName      = $deviceName
    serialNumber    = $serialNumber
    operatingSystem = $os
}

Write-MockLog -Level 'Information' -Message 'Status query received.' -Properties $logProps

# --- Resolve the managed device (unless an explicit id was supplied) ---------
$device = $null
try {
    $device = Get-IntuneManagedDevice `
        -ManagedDeviceId $managedDeviceId `
        -DeviceName $deviceName `
        -SerialNumber $serialNumber `
        -LogProperties $logProps
}
catch {
    Write-MockLog -Level 'Error' -Message "Device lookup failed: $($_.Exception.Message)" -Properties $logProps
    Write-Json -StatusCode 502 -Object @{ error = 'Failed to query Microsoft Graph for the device.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

# Resolve the serial we will use for the Autopilot presence check.
$serialForAutopilot = if ($serialNumber) { $serialNumber } elseif ($device) { [string]$device.serialNumber } else { $null }

# --- Wipe status ------------------------------------------------------------
# A managed device that is gone from Intune usually means the wipe already
# completed (or the object was retired/removed), so treat "not found" as such.
$wipe = $null
try {
    if ($managedDeviceId -or $device) {
        $idForStatus = if ($managedDeviceId) { $managedDeviceId } else { [string]$device.id }
        $wipe = Get-DeviceWipeStatus -ManagedDeviceId $idForStatus -LogProperties $logProps
    }
}
catch {
    Write-MockLog -Level 'Error' -Message "Wipe status query failed: $($_.Exception.Message)" -Properties $logProps
    Write-Json -StatusCode 502 -Object @{ error = 'Failed to read the wipe status from Microsoft Graph.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

$wipeStatus = if ($null -eq $wipe -or -not $wipe.Found) {
    @{
        found  = $false
        state  = 'notFoundInIntune'
        detail = 'Managed device is not present in Intune. If a wipe was issued, it likely completed and the object was removed.'
    }
}
else {
    @{
        found                = $true
        managedDeviceId      = $wipe.ManagedDeviceId
        managementState      = $wipe.ManagementState
        lastSyncDateTime     = $wipe.LastSyncDateTime
        state                = $wipe.WipeState
        startDateTime        = $wipe.WipeStartDateTime
        lastUpdatedDateTime  = $wipe.WipeLastUpdatedDateTime
    }
}

# --- Autopilot status (Windows only) ----------------------------------------
$autopilotStatus = $null
if ($os -eq 'Windows' -or (-not $os -and $serialForAutopilot)) {
    if ($serialForAutopilot) {
        try {
            $ap = Get-AutopilotDeviceStatus -SerialNumber $serialForAutopilot -LogProperties $logProps
            $autopilotStatus = @{
                serialNumber = $serialForAutopilot
                present      = $ap.Present
                removed      = if ($null -eq $ap.Present) { $null } else { -not $ap.Present }
                autopilotDeviceId = $ap.AutopilotDeviceId
            }
        }
        catch {
            Write-MockLog -Level 'Warning' -Message "Autopilot status query failed: $($_.Exception.Message)" -Properties $logProps
            $autopilotStatus = @{ serialNumber = $serialForAutopilot; error = $_.Exception.Message }
        }
    }
    else {
        $autopilotStatus = @{ state = 'unknown'; detail = 'No serialNumber available to check Autopilot.' }
    }
}
else {
    $autopilotStatus = @{ state = 'notApplicable'; detail = 'Autopilot only applies to Windows devices.' }
}

# --- Derive an overall status -----------------------------------------------
$overall = switch ($wipeStatus.state) {
    'done'             { 'WipeCompleted' }
    'notFoundInIntune' { 'WipeCompletedOrRemoved' }
    'failed'           { 'WipeFailed' }
    'inProgress'       { 'WipeInProgress' }
    'pending'          { 'WipePending' }
    'retryPending'     { 'WipeRetryPending' }
    'notIssued'        { 'NoWipeIssued' }
    default            { 'Unknown' }
}

Write-MockLog -Level 'Information' -Message "Status query resolved to $overall." -Properties $logProps

Write-Json -StatusCode 200 -Object @{
    correlationId   = $correlationId
    operatingSystem = $os
    overallStatus   = $overall
    wipe            = $wipeStatus
    autopilot       = $autopilotStatus
    checkedAt       = (Get-Date).ToUniversalTime().ToString('o')
}
