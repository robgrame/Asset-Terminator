#Requires -Version 7.6

using namespace System.Net

# WipeIntake handler - HTTP front door for ServiceNow.
#
# This function never wipes the device itself. It:
#   1. validates the request;
#   2. normalises operatingSystem -> enrollment platform (resolving the ambiguous
#      "Mobile" value against Intune);
#   3. runs the fast, read-only guardrails (device managed by Intune, encryption,
#      user confirmation);
#   4. persists the request state (write-before-action);
#   5. starts the platform runbook directly through Azure Resource Manager;
#   6. answers 202 Accepted with the requestId and a Location header.

param($Request, $TriggerMetadata)

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

function Remove-CurrentDeviceLease {
    param(
        [Parameter(Mandatory)] [string] $SerialNumber,
        [Parameter(Mandatory)] [string] $RequestId,
        [hashtable] $LogProperties
    )

    try {
        Unlock-WipeDevice -SerialNumber $SerialNumber -RequestId $RequestId | Out-Null
    }
    catch {
        Write-AtLog -Level 'Error' -Message "Failed to release the device lease: $($_.Exception.Message)" -Properties $LogProperties
    }
}

$payload = ConvertFrom-JsonBody -Body $Request.Body

# --- Validation -------------------------------------------------------------
if (-not $payload) {
    Write-Json -StatusCode 400 -Object @{ error = 'Request body must be valid JSON.' }
    return
}

$inputSerialNumber = [string](Get-JsonPropertyValue -InputObject $payload -Name 'serialNumber')
$inputImei = [string](Get-JsonPropertyValue -InputObject $payload -Name 'imei')
$inputManagedDeviceId = [string](Get-JsonPropertyValue -InputObject $payload -Name 'managedDeviceId')
$inputDeviceName = [string](Get-JsonPropertyValue -InputObject $payload -Name 'deviceName')
$inputScenario = [string](Get-JsonPropertyValue -InputObject $payload -Name 'scenario')
$inputOperatingSystem = [string](Get-JsonPropertyValue -InputObject $payload -Name 'operatingSystem')
$inputRequestId = [string](Get-JsonPropertyValue -InputObject $payload -Name 'requestId')
$inputDryRun = Get-JsonPropertyValue -InputObject $payload -Name 'dryRun'
$inputUserConfirmed = Get-JsonPropertyValue -InputObject $payload -Name 'userConfirmed'
$inputMdmServerId = [string](Get-JsonPropertyValue -InputObject $payload -Name 'mdmServerId')
$inputCallbackUrl = [string](Get-JsonPropertyValue -InputObject $payload -Name 'callbackUrl')

if (-not $inputSerialNumber -and -not $inputImei -and -not $inputManagedDeviceId -and -not $inputDeviceName) {
    Write-Json -StatusCode 400 -Object @{ error = 'At least one of serialNumber, imei, managedDeviceId or deviceName is required.' }
    return
}

$scenario = ConvertTo-ValidScenario -Scenario $inputScenario
if (-not $scenario) {
    Write-Json -StatusCode 400 -Object @{ error = 'scenario must be one of: Retirement, Sale, Disposal, LostStolen.' }
    return
}

$platform = ConvertTo-EnrollmentPlatform -OperatingSystem $inputOperatingSystem
if (-not $platform) {
    Write-Json -StatusCode 400 -Object @{ error = 'operatingSystem is required and must map to Windows, Apple or Android (aliases: win/macos/ios/ipados/android/mobile).' }
    return
}

$correlationId = [guid]::NewGuid().ToString()
$requestId = if ($inputRequestId) { $inputRequestId } else { $correlationId }

$dryRun = Get-AppSettingBool -Name 'DEFAULT_DRY_RUN' -Default $false
if ($null -ne $inputDryRun) { $dryRun = [System.Convert]::ToBoolean($inputDryRun) }

$logProps = @{
    correlationId = $correlationId
    requestId     = $requestId
    scenario      = $scenario
    platform      = $platform
    serialNumber  = $inputSerialNumber
    dryRun        = $dryRun
}

Write-AtLog -Level 'Information' -Message 'Disposal request received.' -Properties $logProps
Write-AtAudit -Action 'WipeRequestReceived' -Properties $logProps

# --- Idempotency ------------------------------------------------------------
# Same requestId already in flight or done: return the current state instead of
# creating a second job.
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
        -ManagedDeviceId $inputManagedDeviceId `
        -DeviceName $inputDeviceName `
        -SerialNumber $inputSerialNumber `
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

$resolvedSerialNumber = [string]$device.serialNumber
if ([string]::IsNullOrWhiteSpace($resolvedSerialNumber)) {
    Write-AtLog -Level 'Warning' -Message 'The managed device has no serial number and cannot be dispatched.' -Properties $logProps
    Write-Json -StatusCode 422 -Object @{
        requestId = $requestId
        correlationId = $correlationId
        status = 'Rejected'
        reason = 'MissingSerialNumber'
        error = 'The managed device does not expose the serial number required by the platform runbook.'
    }
    return
}
$logProps.serialNumber = $resolvedSerialNumber

$guardrails = [System.Collections.Generic.List[object]]::new()

if (Get-AppSettingBool -Name 'GUARDRAIL_REQUIRE_ENCRYPTION' -Default $true) {
    $encrypted = [bool]$device.isEncrypted
    $guardrails.Add([pscustomobject]@{ name = 'Encryption'; passed = $encrypted; detail = "isEncrypted=$encrypted" })
}

if (Get-AppSettingBool -Name 'GUARDRAIL_REQUIRE_USER_CONFIRMATION' -Default $true) {
    $confirmed = [bool]$inputUserConfirmed
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
        imei            = $inputImei
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
        mdmServerId                  = $inputMdmServerId
        dryRun                       = $dryRun
    }
    callbackUrl   = $inputCallbackUrl
    acceptedAt    = (Get-Date).ToUniversalTime().ToString('o')
}

try {
    $deviceLease = Lock-WipeDevice `
        -SerialNumber $resolvedSerialNumber `
        -RequestId $requestId `
        -Platform $platform
}
catch {
    Write-AtLog -Level 'Error' -Message "Failed to acquire the device lease: $($_.Exception.Message)" -Properties $logProps
    Write-Json -StatusCode 500 -Object @{
        error = 'Failed to reserve the device for this request.'
        detail = $_.Exception.Message
        correlationId = $correlationId
    }
    return
}

if (-not $deviceLease.Acquired) {
    Write-AtLog -Level 'Warning' -Message "Another disposal request is active for this device: $($deviceLease.ActiveRequestId)." -Properties $logProps
    Write-Json -StatusCode 409 -Object @{
        error = 'Another disposal request is already active for this device.'
        requestId = $requestId
        activeRequestId = $deviceLease.ActiveRequestId
        activePlatform = $deviceLease.ActivePlatform
        leaseExpiresAt = $deviceLease.ExpiresAt
        correlationId = $correlationId
    }
    return
}

# --- Write-before-action ----------------------------------------------------
try {
    Save-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        correlationId   = $correlationId
        status          = 'Accepted'
        scenario        = $scenario
        serialNumber    = [string]$device.serialNumber
        imei            = $inputImei
        deviceName      = [string]$device.deviceName
        managedDeviceId = [string]$device.id
        operatingSystem = [string]$device.operatingSystem
        callbackUrl     = $inputCallbackUrl
        dryRun          = $dryRun
        attempts        = 0
        acceptedAt      = (Get-Date).ToUniversalTime()
    } | Out-Null
}
catch {
    Write-AtLog -Level 'Error' -Message "Failed to persist state: $($_.Exception.Message)" -Properties $logProps
    Remove-CurrentDeviceLease -SerialNumber $resolvedSerialNumber -RequestId $requestId -LogProperties $logProps
    Write-Json -StatusCode 500 -Object @{ error = 'Failed to persist the request state.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

# --- Direct runbook dispatch -------------------------------------------------
try {
    $dispatch = Invoke-DisposalDispatch -Message $message -ExpectedPlatform $platform
}
catch {
    $dispatchError = $_.Exception.Message
    try {
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'DispatchFailed'
            errorMessage = $dispatchError
        }
    }
    catch {
        Write-AtLog -Level 'Error' -Message "Failed to persist DispatchFailed state: $($_.Exception.Message)" -Properties $logProps
    }
    Remove-CurrentDeviceLease -SerialNumber $resolvedSerialNumber -RequestId $requestId -LogProperties $logProps
    Write-AtLog -Level 'Error' -Message "Failed to dispatch the runbook: $dispatchError" -Properties $logProps
    Write-Json -StatusCode 502 -Object @{
        error = 'Failed to start the platform runbook.'
        detail = $dispatchError
        requestId = $requestId
        correlationId = $correlationId
        status = 'DispatchFailed'
    }
    return
}

if ($dispatch.Status -eq 'DispatchFailed') {
    Remove-CurrentDeviceLease -SerialNumber $resolvedSerialNumber -RequestId $requestId -LogProperties $logProps
    Write-Json -StatusCode 500 -Object @{
        error = $dispatch.ErrorMessage
        requestId = $requestId
        correlationId = $correlationId
        status = $dispatch.Status
    }
    return
}

if ($dispatch.Status -eq 'Completed') {
    Remove-CurrentDeviceLease -SerialNumber $resolvedSerialNumber -RequestId $requestId -LogProperties $logProps
}

Write-AtLog -Level 'Information' -Message 'Disposal request dispatched directly.' -Properties $logProps
Write-AtAudit -Action 'WipeRequestAccepted' -Properties ($logProps + @{ status = $dispatch.Status })

Write-Json -StatusCode 202 -Object @{
    requestId     = $requestId
    correlationId = $correlationId
    status        = $dispatch.Status
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
    automationJobName = $dispatch.AutomationJobName
    automationJobId   = $dispatch.AutomationJobId
    statusUrl     = "/api/v1/wipe/status?requestId=$requestId"
} -ExtraHeaders @{ 'Location' = "/api/v1/wipe/status?requestId=$requestId" }
