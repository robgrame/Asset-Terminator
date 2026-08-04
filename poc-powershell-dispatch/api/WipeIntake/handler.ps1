#Requires -Version 7.6

using namespace System.Net

# WipeIntake handler - HTTP front door for ServiceNow.
#
# Unlike the synchronous mock, this function never touches the device. It:
#   1. validates the request;
#   2. normalises operatingSystem -> enrollment platform (resolving the ambiguous
#      "Mobile" value against Intune);
#   3. runs the fast, read-only guardrails (device managed by Intune, encryption,
#      user confirmation);
#   4. persists the request state (write-before-action);
#   5. publishes the canonical message on the Service Bus topic;
#   6. answers 202 Accepted with the requestId and a Location header.
#
# The actual wipe is performed by the platform runbooks, started by the worker.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/AT.Common.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/AT.Graph.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/AT.State.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/AT.Messaging.psm1" -Force

function Write-Json {
    param([int] $StatusCode, $Object, [hashtable] $ExtraHeaders)

    $headers = @{ 'Content-Type' = 'application/json' }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] } }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = $headers
        Body       = ($Object | ConvertTo-Json -Depth 10)
    })
}

$payload = ConvertFrom-JsonBody -Body $Request.Body

# --- Validation -------------------------------------------------------------
if (-not $payload) {
    Write-Json -StatusCode 400 -Object @{ error = 'Request body must be valid JSON.' }
    return
}

if (-not $payload.serialNumber -and -not $payload.imei -and -not $payload.managedDeviceId -and -not $payload.deviceName) {
    Write-Json -StatusCode 400 -Object @{ error = 'At least one of serialNumber, imei, managedDeviceId or deviceName is required.' }
    return
}

$scenario = ConvertTo-ValidScenario -Scenario ([string]$payload.scenario)
if (-not $scenario) {
    Write-Json -StatusCode 400 -Object @{ error = 'scenario must be one of: Retirement, Sale, Disposal, LostStolen.' }
    return
}

$platform = ConvertTo-EnrollmentPlatform -OperatingSystem ([string]$payload.operatingSystem)
if (-not $platform) {
    Write-Json -StatusCode 400 -Object @{ error = 'operatingSystem is required and must map to Windows, Apple or Android (aliases: win/macos/ios/ipados/android/mobile).' }
    return
}

$correlationId = [guid]::NewGuid().ToString()
$requestId = if ($payload.requestId) { [string]$payload.requestId } else { $correlationId }

$dryRun = Get-AppSettingBool -Name 'DEFAULT_DRY_RUN' -Default $false
if ($null -ne $payload.dryRun) { $dryRun = [System.Convert]::ToBoolean($payload.dryRun) }

$logProps = @{
    correlationId = $correlationId
    requestId     = $requestId
    scenario      = $scenario
    platform      = $platform
    serialNumber  = [string]$payload.serialNumber
    dryRun        = $dryRun
}

Write-AtLog -Level 'Information' -Message 'Disposal request received.' -Properties $logProps
Write-AtAudit -Action 'WipeRequestReceived' -Properties $logProps

# --- Idempotency ------------------------------------------------------------
# Same requestId already in flight or done: return the current state instead of
# creating a second job. Service Bus duplicate detection is the second line of
# defence, this one keeps the answer meaningful for ServiceNow.
try {
    $existing = Find-WipeRequestState -Filter "RowKey eq '$requestId'" -Top 1
    if ($existing.Count -gt 0) {
        Write-AtLog -Level 'Warning' -Message 'Duplicate requestId, returning existing state.' -Properties $logProps
        Write-Json -StatusCode 200 -Object @{
            requestId     = $requestId
            correlationId = $existing[0].correlationId
            status        = $existing[0].status
            duplicate     = $true
        }
        return
    }
}
catch {
    Write-AtLog -Level 'Warning' -Message "State store lookup failed, continuing: $($_.Exception.Message)" -Properties $logProps
}

# --- Device resolution + guardrails -----------------------------------------
$device = $null
try {
    $device = Get-IntuneManagedDevice `
        -ManagedDeviceId ([string]$payload.managedDeviceId) `
        -DeviceName ([string]$payload.deviceName) `
        -SerialNumber ([string]$payload.serialNumber) `
        -LogProperties $logProps
}
catch {
    Write-AtLog -Level 'Error' -Message "Device lookup failed: $($_.Exception.Message)" -Properties $logProps
    Write-Json -StatusCode 502 -Object @{ error = 'Failed to query Microsoft Graph for the device.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

# Guardrail: the process requires a manual task when the device is not managed.
if (-not $device) {
    Write-AtLog -Level 'Warning' -Message 'Managed device not found in Intune: routed to manual handling.' -Properties $logProps
    Write-AtAudit -Action 'WipeRequestRejected' -Level 'Warning' -Properties ($logProps + @{ status = 'Rejected'; reason = 'DeviceNotManagedByIntune' })
    Write-Json -StatusCode 422 -Object @{
        requestId     = $requestId
        correlationId = $correlationId
        status        = 'Rejected'
        reason        = 'DeviceNotManagedByIntune'
        error         = 'Managed device not found in Intune. ServiceNow must open a manual task.'
    }
    return
}

# "Mobile" is ambiguous: Intune is the authoritative source for iOS vs Android.
if ($platform -eq 'Mobile') {
    $platform = ConvertTo-EnrollmentPlatform -OperatingSystem ([string]$device.operatingSystem)
    if (-not $platform -or $platform -eq 'Mobile') {
        Write-Json -StatusCode 422 -Object @{
            requestId = $requestId; correlationId = $correlationId; status = 'Rejected'
            reason = 'AmbiguousPlatform'
            error  = "Unable to resolve the enrollment platform from Intune operatingSystem '$($device.operatingSystem)'."
        }
        return
    }
    $logProps.platform = $platform
}

$guardrails = [System.Collections.Generic.List[object]]::new()

if (Get-AppSettingBool -Name 'GUARDRAIL_REQUIRE_ENCRYPTION' -Default $true) {
    $encrypted = [bool]$device.isEncrypted
    $guardrails.Add([pscustomobject]@{ name = 'Encryption'; passed = $encrypted; detail = "isEncrypted=$encrypted" })
}

if (Get-AppSettingBool -Name 'GUARDRAIL_REQUIRE_USER_CONFIRMATION' -Default $true) {
    $confirmed = [bool]$payload.userConfirmed
    $guardrails.Add([pscustomobject]@{ name = 'UserConfirmation'; passed = $confirmed; detail = "userConfirmed=$confirmed" })
}

$failed = @($guardrails | Where-Object { -not $_.passed })
if ($failed.Count -gt 0 -and -not $dryRun) {
    Write-AtLog -Level 'Warning' -Message 'Guardrails failed: routed to manual handling.' -Properties $logProps
    Write-AtAudit -Action 'WipeRequestRejected' -Level 'Warning' -Properties ($logProps + @{ status = 'Rejected'; reason = 'GuardrailFailed'; guardrails = (($failed.name) -join ',') })

    try {
        Save-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            correlationId = $correlationId; status = 'Rejected'; scenario = $scenario
            serialNumber  = [string]$device.serialNumber; deviceName = [string]$device.deviceName
            managedDeviceId = [string]$device.id
            errorMessage  = "Guardrails failed: $(($failed.name) -join ', ')"
            acceptedAt    = (Get-Date).ToUniversalTime()
        } | Out-Null
    }
    catch { Write-AtLog -Level 'Error' -Message "Failed to persist rejected state: $($_.Exception.Message)" -Properties $logProps }

    Write-Json -StatusCode 422 -Object @{
        requestId = $requestId; correlationId = $correlationId; status = 'Rejected'
        reason = 'GuardrailFailed'; guardrails = $guardrails
    }
    return
}

# --- Canonical message ------------------------------------------------------
$removeFromPlatform = Test-RemoveFromEnrollmentPlatform -Scenario $scenario

$message = [ordered]@{
    schemaVersion = '1.0'
    requestId     = $requestId
    correlationId = $correlationId
    platform      = $platform
    scenario      = $scenario
    device        = [ordered]@{
        serialNumber    = [string]$device.serialNumber
        imei            = [string]$payload.imei
        deviceName      = [string]$device.deviceName
        managedDeviceId = [string]$device.id
        operatingSystem = [string]$device.operatingSystem
        osVersion       = [string]$device.osVersion
        isEncrypted     = [bool]$device.isEncrypted
    }
    options       = [ordered]@{
        removeFromEnrollmentPlatform = $removeFromPlatform
        keepUserData                 = (Get-AppSettingBool -Name 'WIPE_KEEP_USER_DATA' -Default $false)
        keepEnrollmentData           = (Get-AppSettingBool -Name 'WIPE_KEEP_ENROLLMENT_DATA' -Default $false)
        mdmServerId                  = [string]$payload.mdmServerId
        dryRun                       = $dryRun
    }
    callbackUrl   = [string]$payload.callbackUrl
    enqueuedAt    = (Get-Date).ToUniversalTime().ToString('o')
}

# --- Write-before-action ----------------------------------------------------
try {
    Save-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        correlationId   = $correlationId
        status          = 'Accepted'
        scenario        = $scenario
        serialNumber    = [string]$device.serialNumber
        imei            = [string]$payload.imei
        deviceName      = [string]$device.deviceName
        managedDeviceId = [string]$device.id
        operatingSystem = [string]$device.operatingSystem
        callbackUrl     = [string]$payload.callbackUrl
        dryRun          = $dryRun
        attempts        = 0
        acceptedAt      = (Get-Date).ToUniversalTime()
    } | Out-Null
}
catch {
    Write-AtLog -Level 'Error' -Message "Failed to persist state: $($_.Exception.Message)" -Properties $logProps
    Write-Json -StatusCode 500 -Object @{ error = 'Failed to persist the request state.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

# --- Publish ----------------------------------------------------------------
try {
    Send-ServiceBusMessage `
        -Entity (Get-AppSetting -Name 'SERVICEBUS_TOPIC' -Default 'asset-disposal') `
        -Body $message `
        -MessageId $requestId `
        -SessionId ([string]$device.serialNumber) `
        -CorrelationId $correlationId `
        -ApplicationProperties @{ platform = $platform; scenario = $scenario; dryRun = $dryRun } | Out-Null

    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        status = 'Queued'; queuedAt = (Get-Date).ToUniversalTime()
    }
}
catch {
    Write-AtLog -Level 'Error' -Message "Failed to publish message: $($_.Exception.Message)" -Properties $logProps
    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        status = 'Rejected'; errorMessage = "Publish failed: $($_.Exception.Message)"
    }
    Write-Json -StatusCode 500 -Object @{ error = 'Failed to queue the request.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

Write-AtLog -Level 'Information' -Message 'Disposal request queued.' -Properties $logProps
Write-AtAudit -Action 'WipeRequestQueued' -Properties ($logProps + @{ status = 'Queued' })

Write-Json -StatusCode 202 -Object @{
    requestId     = $requestId
    correlationId = $correlationId
    status        = 'Queued'
    platform      = $platform
    scenario      = $scenario
    dryRun        = $dryRun
    device        = @{
        managedDeviceId = [string]$device.id
        deviceName      = [string]$device.deviceName
        serialNumber    = [string]$device.serialNumber
        operatingSystem = [string]$device.operatingSystem
    }
    guardrails    = $guardrails
    statusUrl     = "/api/v1/wipe/status?requestId=$requestId"
} -ExtraHeaders @{ 'Location' = "/api/v1/wipe/status?requestId=$requestId" }
