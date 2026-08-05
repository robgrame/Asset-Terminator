#Requires -Version 7.6

using namespace System.Net

# WipeIntake handler - HTTP front door for ServiceNow.
#
# This function never wipes the device itself, and it never blocks on the
# runbook finishing. It:
#   1. validates the request;
#   2. atomically registers the requestId in a global index (PartitionKey
#      '__RequestId') so a retried/duplicated POST can never create two
#      dispatch attempts: same id + same content replays the current state,
#      same id + different content is rejected with 409 and never overwrites
#      the original;
#   3. normalises operatingSystem -> enrollment platform (resolving the
#      ambiguous "Mobile" value against Intune) and rejects a payload whose
#      declared platform disagrees with Intune's authoritative record;
#   4. runs the fast, read-only guardrails (device managed by Intune,
#      encryption, user confirmation) and persists every Rejected outcome so
#      GetStatus can always answer for a requestId that was ever accepted for
#      processing;
#   5. persists the full canonical payload with status=Accepted BEFORE any
#      dispatch attempt is made (write-before-action / durable handoff): if
#      the Function App crashes or restarts right here, JobMonitor's
#      reconciliation pass still has everything it needs to dispatch the
#      runbook, because it reads this same persisted payload;
#   6. makes one optional, best-effort immediate dispatch attempt through
#      Azure Resource Manager. Success or failure of this attempt never
#      changes the durability guarantee from step 5: an ambiguous or
#      transient failure here is left for JobMonitor to retry with backoff,
#      never surfaced to the caller as a hard failure;
#   7. answers 202 Accepted with the requestId and a Location header.

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

function Save-RejectedRequest {
    <#
    .SYNOPSIS
        Persists every 'Rejected' outcome (reason/error/completedAt) so a
        requestId that reached domain-level validation never 404s on GetStatus,
        even though no dispatch was ever attempted for it.
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [hashtable] $Properties,
        [hashtable] $LogProperties
    )

    try {
        Save-WipeRequestState -Platform $Platform -RequestId $RequestId -Properties (
            @{ status = 'Rejected'; completedAt = (Get-Date).ToUniversalTime() } + $Properties
        ) | Out-Null
    }
    catch {
        Write-AtLog -Level 'Error' -Message "Failed to persist rejected state: $($_.Exception.Message)" -Properties $LogProperties
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

# --- Atomic requestId idempotency gate ---------------------------------------
# The hash covers only what the CALLER supplied (never server-generated fields
# such as correlationId/acceptedAt): a legitimate retry of the exact same
# request must always compute the same hash so it can be replayed safely.
$hashInput = [ordered]@{
    requestId       = $requestId
    scenario        = $inputScenario
    operatingSystem = $inputOperatingSystem
    serialNumber    = $inputSerialNumber
    imei            = $inputImei
    managedDeviceId = $inputManagedDeviceId
    deviceName      = $inputDeviceName
    dryRun          = "$dryRun"
    userConfirmed   = "$([bool]$inputUserConfirmed)"
    mdmServerId     = $inputMdmServerId
    callbackUrl     = $inputCallbackUrl
}
$payloadHash = Get-PayloadHash -InputObject $hashInput

try {
    $registration = Register-RequestIdIndex -RequestId $requestId -Platform $platform -PayloadHash $payloadHash
}
catch {
    Write-AtLog -Level 'Error' -Message "State store idempotency check failed: $($_.Exception.Message)" -Properties $logProps
    Write-Json -StatusCode 502 -Object @{ error = 'Failed to check request idempotency.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

if (-not $registration.Registered) {
    if ($registration.Conflict) {
        Write-AtLog -Level 'Warning' -Message 'requestId reused with different content: rejected without overwriting the original request.' -Properties $logProps
        Write-AtAudit -Action 'WipeRequestIdConflict' -Level 'Warning' -Properties $logProps
        Write-Json -StatusCode 409 -Object @{
            error         = 'requestId was already used with different request content. Use a new requestId for a different request.'
            requestId     = $requestId
            correlationId = $correlationId
        }
        return
    }

    # Same requestId, same content: safe replay. Return the current durable
    # state instead of creating a second job.
    Write-AtLog -Level 'Warning' -Message 'Duplicate requestId with identical content, returning existing state.' -Properties $logProps
    $existing = $null
    try {
        # The index remembers the platform as first declared, which for a
        # "Mobile" request is resolved (Windows/Apple/Android excluded) only
        # AFTER the index write: the state row can therefore live in a
        # different partition than $registration.Platform. Try the fast path
        # first, then fall back to a partition-agnostic lookup by RowKey.
        $existing = Get-WipeRequestState -Platform $registration.Platform -RequestId $requestId
        if (-not $existing) {
            $candidates = @(Find-WipeRequestState -Filter "PartitionKey ne '__RequestId' and RowKey eq '$($requestId.Replace("'", "''"))'" -Top 1)
            if ($candidates.Count -gt 0) { $existing = $candidates[0] }
        }
    }
    catch {
        Write-AtLog -Level 'Warning' -Message "State store lookup for the existing request failed: $($_.Exception.Message)" -Properties $logProps
    }

    if ($existing) {
        Write-Json -StatusCode 200 -Object @{
            requestId     = $requestId
            correlationId = (Get-JsonPropertyValue -InputObject $existing -Name 'correlationId')
            status        = (Get-JsonPropertyValue -InputObject $existing -Name 'status')
            duplicate     = $true
        }
        return
    }

    # Registered a moment ago by a concurrent request that has not finished
    # persisting the state row yet: it is in flight, not lost.
    Write-Json -StatusCode 202 -Object @{
        requestId     = $requestId
        correlationId = $correlationId
        status        = 'Accepted'
        duplicate      = $true
    }
    return
}

# --- Device resolution + guardrails -----------------------------------------
$device = $null
try {
    $device = Get-IntuneManagedDevice `
        -ManagedDeviceId $inputManagedDeviceId `
        -DeviceName $inputDeviceName `
        -SerialNumber $inputSerialNumber `
        -Imei $inputImei `
        -LogProperties $logProps
}
catch {
    # A genuine Graph failure (auth, RBAC, throttling, 5xx, ...) is NEVER
    # reinterpreted as "device not managed": only an empty/404 result is.
    Write-AtLog -Level 'Error' -Message "Device lookup failed: $($_.Exception.Message)" -Properties $logProps
    Write-Json -StatusCode 502 -Object @{ error = 'Failed to query Microsoft Graph for the device.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

# Guardrail: the process requires a manual task when the device is not managed.
if (-not $device) {
    Write-AtLog -Level 'Warning' -Message 'Managed device not found in Intune: routed to manual handling.' -Properties $logProps
    Write-AtAudit -Action 'WipeRequestRejected' -Level 'Warning' -Properties ($logProps + @{ status = 'Rejected'; reason = 'DeviceNotManagedByIntune' })
    Save-RejectedRequest -Platform $platform -RequestId $requestId -LogProperties $logProps -Properties @{
        correlationId = $correlationId; scenario = $scenario; serialNumber = $inputSerialNumber; imei = $inputImei
        reason = 'DeviceNotManagedByIntune'
        errorMessage = 'Managed device not found in Intune. ServiceNow must open a manual task.'
    }
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
        Save-RejectedRequest -Platform 'Mobile' -RequestId $requestId -LogProperties $logProps -Properties @{
            correlationId = $correlationId; scenario = $scenario; serialNumber = [string]$device.serialNumber
            managedDeviceId = [string]$device.id; deviceName = [string]$device.deviceName
            reason = 'AmbiguousPlatform'
            errorMessage = "Unable to resolve the enrollment platform from Intune operatingSystem '$($device.operatingSystem)'."
        }
        Write-Json -StatusCode 422 -Object @{
            requestId = $requestId; correlationId = $correlationId; status = 'Rejected'
            reason = 'AmbiguousPlatform'
            error  = "Unable to resolve the enrollment platform from Intune operatingSystem '$($device.operatingSystem)'."
        }
        return
    }
    $logProps.platform = $platform
}
else {
    # The caller declared a concrete platform: Intune's own record is still
    # authoritative and a mismatch must be rejected rather than silently
    # dispatched to the wrong runbook.
    $intunePlatform = ConvertTo-EnrollmentPlatform -OperatingSystem ([string]$device.operatingSystem)
    if ($intunePlatform -and $intunePlatform -ne 'Mobile' -and $intunePlatform -ne $platform) {
        Write-AtLog -Level 'Warning' -Message "Payload platform '$platform' does not match Intune's operatingSystem '$($device.operatingSystem)' (resolved '$intunePlatform')." -Properties $logProps
        Write-AtAudit -Action 'WipeRequestRejected' -Level 'Warning' -Properties ($logProps + @{ status = 'Rejected'; reason = 'PlatformMismatch' })
        Save-RejectedRequest -Platform $platform -RequestId $requestId -LogProperties $logProps -Properties @{
            correlationId = $correlationId; scenario = $scenario; serialNumber = [string]$device.serialNumber
            managedDeviceId = [string]$device.id; deviceName = [string]$device.deviceName
            reason = 'PlatformMismatch'
            errorMessage = "Requested platform '$platform' does not match the device's Intune platform '$intunePlatform'."
        }
        Write-Json -StatusCode 422 -Object @{
            requestId = $requestId; correlationId = $correlationId; status = 'Rejected'
            reason = 'PlatformMismatch'
            error  = "Requested platform '$platform' does not match the device's Intune platform '$intunePlatform' (operatingSystem='$($device.operatingSystem)')."
        }
        return
    }
}

# When the caller supplied an IMEI, it must belong to the resolved device:
# otherwise the wrong physical asset could be wiped under the right serial.
if (-not [string]::IsNullOrWhiteSpace($inputImei) -and
    -not [string]::IsNullOrWhiteSpace([string]$device.imei) -and
    $inputImei -ne [string]$device.imei) {
    Write-AtLog -Level 'Warning' -Message 'Supplied imei does not match the resolved device record.' -Properties $logProps
    Write-AtAudit -Action 'WipeRequestRejected' -Level 'Warning' -Properties ($logProps + @{ status = 'Rejected'; reason = 'DeviceIdentityMismatch' })
    Save-RejectedRequest -Platform $platform -RequestId $requestId -LogProperties $logProps -Properties @{
        correlationId = $correlationId; scenario = $scenario; serialNumber = [string]$device.serialNumber
        managedDeviceId = [string]$device.id; deviceName = [string]$device.deviceName; imei = $inputImei
        reason = 'DeviceIdentityMismatch'
        errorMessage = "Supplied imei '$inputImei' does not match the resolved device's imei."
    }
    Write-Json -StatusCode 422 -Object @{
        requestId = $requestId; correlationId = $correlationId; status = 'Rejected'
        reason = 'DeviceIdentityMismatch'
        error  = "Supplied imei does not match the resolved device's imei."
    }
    return
}

$resolvedSerialNumber = [string]$device.serialNumber
if ([string]::IsNullOrWhiteSpace($resolvedSerialNumber)) {
    Write-AtLog -Level 'Warning' -Message 'The managed device has no serial number and cannot be dispatched.' -Properties $logProps
    Save-RejectedRequest -Platform $platform -RequestId $requestId -LogProperties $logProps -Properties @{
        correlationId = $correlationId; scenario = $scenario; managedDeviceId = [string]$device.id; deviceName = [string]$device.deviceName
        reason = 'MissingSerialNumber'
        errorMessage = 'The managed device does not expose the serial number required by the platform runbook.'
    }
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

    Save-RejectedRequest -Platform $platform -RequestId $requestId -LogProperties $logProps -Properties @{
        correlationId = $correlationId; scenario = $scenario
        serialNumber  = [string]$device.serialNumber; deviceName = [string]$device.deviceName
        managedDeviceId = [string]$device.id
        reason        = 'GuardrailFailed'
        errorMessage  = "Guardrails failed: $(($failed.name) -join ', ')"
    }

    Write-Json -StatusCode 422 -Object @{
        requestId = $requestId; correlationId = $correlationId; status = 'Rejected'
        reason = 'GuardrailFailed'; guardrails = $guardrails
    }
    return
}

# --- Canonical message -------------------------------------------------------
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

# --- Write-before-action: durable handoff ------------------------------------
# The full canonical payload is persisted BEFORE any dispatch attempt. If the
# process is recycled right here, JobMonitor's reconciliation pass finds this
# same row (status=Accepted, payloadJson set) and dispatches it - no HTTP
# request needs to be replayed for the disposal to still happen.
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
        payloadHash     = $payloadHash
        payloadJson     = $message
        acceptedAt      = (Get-Date).ToUniversalTime()
    } | Out-Null
}
catch {
    Write-AtLog -Level 'Error' -Message "Failed to persist state: $($_.Exception.Message)" -Properties $logProps
    Remove-CurrentDeviceLease -SerialNumber $resolvedSerialNumber -RequestId $requestId -LogProperties $logProps
    Write-Json -StatusCode 500 -Object @{ error = 'Failed to persist the request state.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

# --- Optional immediate dispatch attempt -------------------------------------
# Best-effort only: claim the row we just created (an ETag-conditional MERGE,
# exactly like JobMonitor's reconciliation pass uses) so this attempt and a
# concurrent JobMonitor tick can never both start the runbook job. If the
# claim is lost, JobMonitor already owns the request and will finish it; the
# caller simply gets 202 Accepted back.
$dispatch = $null
try {
    $claim = Invoke-DispatchClaim -Platform $platform -RequestId $requestId
    if ($claim.Claimed) {
        $dispatch = Invoke-DisposalDispatch -Message $message -ExpectedPlatform $platform -Attempt 1
    }
    else {
        Write-AtLog -Level 'Information' -Message "Immediate dispatch skipped ($($claim.Reason)); JobMonitor will reconcile." -Properties $logProps
    }
}
catch {
    # The immediate attempt is an optimisation: any unexpected failure here
    # (including a claim/dispatch bug) must not surface as an HTTP failure,
    # because the durable Accepted row already guarantees JobMonitor will try.
    Write-AtLog -Level 'Error' -Message "Immediate dispatch attempt failed unexpectedly, deferring to JobMonitor: $($_.Exception.Message)" -Properties $logProps
}

if (-not $dispatch) {
    Write-AtAudit -Action 'WipeRequestAccepted' -Properties ($logProps + @{ status = 'Accepted' })
    Write-Json -StatusCode 202 -Object @{
        requestId     = $requestId
        correlationId = $correlationId
        status        = 'Accepted'
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
    return
}

if ($dispatch.ReleaseLease) {
    Remove-CurrentDeviceLease -SerialNumber $resolvedSerialNumber -RequestId $requestId -LogProperties $logProps
}

if ($dispatch.Status -eq 'DispatchFailed') {
    Write-Json -StatusCode 500 -Object @{
        error = $dispatch.ErrorMessage
        requestId = $requestId
        correlationId = $correlationId
        status = $dispatch.Status
    }
    return
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
    guardrails        = $guardrails
    automationJobName = $dispatch.AutomationJobName
    automationJobId   = $dispatch.AutomationJobId
    statusUrl         = "/api/v1/wipe/status?requestId=$requestId"
} -ExtraHeaders @{ 'Location' = "/api/v1/wipe/status?requestId=$requestId" }
