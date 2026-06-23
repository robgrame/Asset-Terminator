using namespace System.Net

# WipeIntake - HTTP trigger
# Receives a wipe request (from ServiceNow / curl), validates it, and enqueues
# it onto the Service Bus queue for asynchronous processing. Returns 202 Accepted
# with a correlationId the caller can use for tracking.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/Common.psm1" -Force

# The PowerShell worker may surface the body as a parsed object or a raw string.
$payload = $Request.Body
if ($payload -is [string]) {
    try { $payload = $payload | ConvertFrom-Json } catch { $payload = $null }
}

function Write-Problem {
    param([int] $StatusCode, [string] $Message)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{ error = $Message } | ConvertTo-Json)
    })
}

# --- Validation -------------------------------------------------------------
if (-not $payload) {
    Write-Problem -StatusCode 400 -Message 'Request body must be valid JSON.'
    return
}

if (-not $payload.managedDeviceId -and -not $payload.deviceName -and -not $payload.serialNumber) {
    Write-Problem -StatusCode 400 -Message 'At least one of managedDeviceId, deviceName or serialNumber is required.'
    return
}

$correlationId = New-CorrelationId
$requestId = if ($payload.requestId) { [string]$payload.requestId } else { $correlationId }

# Default to DRY-RUN unless the caller explicitly opts in to a real wipe.
$dryRun = $true
if ($null -ne $payload.dryRun) { $dryRun = [System.Convert]::ToBoolean($payload.dryRun) }

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

# Enqueue onto Service Bus via the output binding.
Push-OutputBinding -Name OutMessage -Value ($message | ConvertTo-Json -Depth 6)

Write-PocLog -Level 'Information' -Message 'Wipe request accepted and enqueued.' -Properties @{
    correlationId   = $correlationId
    requestId       = $requestId
    managedDeviceId = $payload.managedDeviceId
    deviceName      = $payload.deviceName
    serialNumber    = $payload.serialNumber
    dryRun          = $dryRun
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::Accepted
    Headers    = @{ 'Content-Type' = 'application/json' }
    Body       = (@{
        status        = 'Accepted'
        requestId     = $requestId
        correlationId = $correlationId
        dryRun        = $dryRun
    } | ConvertTo-Json)
})
