using namespace System.Net

# WipeIntake - HTTP trigger (Intake Function App, internet-facing)
# Receives a wipe request (from ServiceNow / curl), validates it, enforces
# idempotency on requestId via Table Storage, persists the initial state and -
# only for genuinely new requests - enqueues it onto Service Bus for asynchronous
# processing. Returns 202 Accepted with a correlationId for tracking.
#
# This app holds NO Microsoft Graph permissions: its identity can only write to
# the state table and send to the Service Bus queue. The privileged Graph/wipe
# work lives in the separate Processor Function App.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/Common.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/StateStore.psm1" -Force

# The PowerShell worker may surface the body as a parsed object or a raw string.
$payload = $Request.Body
if ($payload -is [string]) {
    try { $payload = $payload | ConvertFrom-Json } catch { $payload = $null }
}

function Write-Json {
    param([int] $StatusCode, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = ($Object | ConvertTo-Json -Depth 6)
    })
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

$correlationId = New-CorrelationId
$requestId = if ($payload.requestId) { [string]$payload.requestId } else { $correlationId }

# Default to DRY-RUN unless the caller explicitly opts in to a real wipe.
$dryRun = $true
if ($null -ne $payload.dryRun) { $dryRun = [System.Convert]::ToBoolean($payload.dryRun) }

$logProps = @{
    correlationId   = $correlationId
    requestId       = $requestId
    managedDeviceId = $payload.managedDeviceId
    deviceName      = $payload.deviceName
    serialNumber    = $payload.serialNumber
    dryRun          = $dryRun
}

# --- Idempotency + initial state -------------------------------------------
try {
    Initialize-StateTable

    $stateProps = @{
        CorrelationId   = $correlationId
        ManagedDeviceId = [string]$payload.managedDeviceId
        DeviceName      = [string]$payload.deviceName
        SerialNumber    = [string]$payload.serialNumber
        TicketNumber    = [string]$payload.ticketNumber
        Requestor       = [string]$payload.requestor
        DryRun          = $dryRun
    }

    $guard = New-DecommissionStateIfAbsent -RequestId $requestId -Status 'Requested' -Properties $stateProps

    if (-not $guard.Created) {
        # Duplicate requestId: do NOT enqueue again. Return the original tracking id.
        $existing = $guard.Entity
        Write-PocLog -Level 'Warning' -Message 'Duplicate requestId; returning existing state (idempotent).' -Properties $logProps
        Write-Json -StatusCode 200 -Object @{
            status        = 'AlreadyAccepted'
            requestId     = $requestId
            correlationId = $existing.CorrelationId
            overallStatus = $existing.OverallStatus
            dryRun        = $existing.DryRun
        }
        return
    }
}
catch {
    Write-PocLog -Level 'Error' -Message "Failed to persist request state: $($_.Exception.Message)" -Properties $logProps
    Write-Json -StatusCode 500 -Object @{ error = 'Failed to persist request state.' }
    return
}

# --- Enqueue for asynchronous processing ------------------------------------
$message = [ordered]@{
    requestId       = $requestId
    correlationId   = $correlationId
    managedDeviceId = $payload.managedDeviceId
    deviceName      = $payload.deviceName
    serialNumber    = $payload.serialNumber
    ticketNumber    = $payload.ticketNumber
    requestor       = $payload.requestor
    dryRun          = $dryRun
    enqueuedAt      = (Get-Date).ToUniversalTime().ToString('o')
}

Push-OutputBinding -Name OutMessage -Value ($message | ConvertTo-Json -Depth 6)

Write-PocLog -Level 'Information' -Message 'Wipe request accepted and enqueued.' -Properties $logProps

Write-Json -StatusCode ([int][HttpStatusCode]::Accepted) -Object @{
    status        = 'Accepted'
    requestId     = $requestId
    correlationId = $correlationId
    dryRun        = $dryRun
}
