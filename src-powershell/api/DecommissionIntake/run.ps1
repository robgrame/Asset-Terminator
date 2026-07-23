using namespace System.Net

# DecommissionIntake — HTTP POST v1/decommission
# Parity with AssetTerminator.Api DecommissionIntakeFunction + IntakeService.
# Validates a ServiceNow decommission request, idempotently persists the initial
# state (SQL), writes the "RequestReceived" WORM audit record, and enqueues the
# orchestration workflow. Returns 202 Accepted with a correlationId.

param($Request, $TriggerMetadata)

$ingestion = Get-IngestionOptions
$deny = Test-HttpAuthGate -Request $Request -Config $ingestion
if ($deny) { Write-HttpJson -StatusCode $deny.StatusCode -Body @{ status = $deny.StatusCode; detail = $deny.Detail }; return }

$rawJson = if ($Request.Body -is [string]) { $Request.Body } elseif ($Request.Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Request.Body) } else { $Request.Body | ConvertTo-Json -Depth 8 }
$payload = ConvertTo-RequestObject -Body $Request.Body
if (-not $payload) { Write-HttpJson -StatusCode 400 -Body @{ status = 400; detail = 'Request body must be valid JSON.' }; return }

# --- Validation (parity with IntakeService.Validate) ------------------------
$validationError = Test-DecommissionRequest -Request $payload
if ($validationError) { Write-HttpJson -StatusCode 400 -Body @{ status = 400; detail = $validationError }; return }

$correlationId = New-CorrelationId
$requestId = [string]$payload.requestId
$now = [datetime]::UtcNow
$assetCategory = $payload.assetCategory
$preWipe = Get-PreWipeOptions
$dueAt = Get-SlaDueAt -Category $assetCategory -CreatedAtUtc $now

$logProps = @{ correlationId = $correlationId; requestId = $requestId; assetId = $payload.assetId; ticketNumber = (Get-OptionalProp $payload 'ticketNumber'); dryRun = [bool](Get-OptionalProp $payload 'dryRun') }

$record = New-DecommissionRecord -Request $payload -CorrelationId $correlationId -NowUtc $now -DueAtUtc $dueAt -PreWipe $preWipe
$record | Add-Member -NotePropertyName 'requestJson' -NotePropertyValue $rawJson -Force

# --- Idempotent persist (parity with GetOrCreateAsync) ----------------------
try {
    $guard = New-DecommissionRequestRow -Record $record
}
catch {
    Write-AtLog -Level 'Error' -Message "Failed to persist request state: $($_.Exception.Message)" -Properties $logProps
    Write-HttpJson -StatusCode 500 -Body @{ status = 500; detail = 'Failed to persist request state.' }
    return
}

$statusUrl = "/api/v1/decommission/$requestId"

if (-not $guard.Created) {
    # Idempotent replay: do not start a second workflow.
    Write-AtLog -Message "Idempotent replay of $requestId" -Properties $logProps
    Write-HttpJson -StatusCode 202 -Body @{ requestId = $requestId; correlationId = $guard.Record.correlationId; status = 'Accepted'; statusUrl = $statusUrl }
    return
}

# --- Audit + workflow start + telemetry (best-effort for observability) ------
try {
    Add-AuditRecord -Record (New-AuditRecord -CorrelationId $correlationId -RequestId $requestId `
            -TicketNumber (Get-OptionalProp $payload 'ticketNumber') -AssetId $payload.assetId `
            -Action 'RequestReceived' -Actor ((Get-OptionalProp $payload 'requestor') ?? 'servicenow') `
            -Outcome 'Accepted' -Reason ($(if ([bool](Get-OptionalProp $payload 'dryRun')) { 'dry-run' } else { $null })))
}
catch { Write-AtLog -Level 'Warning' -Message "Audit append failed: $($_.Exception.Message)" -Properties $logProps }

try { Start-DecommissionWorkflow -RequestId $requestId -CorrelationId $correlationId }
catch {
    Write-AtLog -Level 'Error' -Message "Failed to enqueue workflow: $($_.Exception.Message)" -Properties $logProps
    Write-HttpJson -StatusCode 500 -Body @{ status = 500; detail = 'Failed to start workflow.' }
    return
}

try { Send-RequestSnapshot -Record $guard.Record } catch { }

Write-AtLog -Message 'Decommission request accepted and enqueued.' -Properties $logProps
Write-HttpJson -StatusCode 202 -Body @{ requestId = $requestId; correlationId = $correlationId; status = 'Accepted'; statusUrl = $statusUrl }
