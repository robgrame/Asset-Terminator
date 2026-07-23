using namespace System.Net

param($Message, $TriggerMetadata)

# Service Bus-triggered starter. Consumes the WorkflowStartMessage placed on the
# orchestration queue by the HTTP intake and schedules the Durable orchestration.
# The requestId is used as the orchestration instance id so a duplicate start is
# ignored — preserving idempotency end-to-end (parity with WorkflowStartFunction.cs).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$body = if ($Message -is [string]) { $Message } else { $Message | ConvertTo-Json -Depth 20 }

$message = $null
try { $message = $body | ConvertFrom-Json } catch { }

$requestId = if ($message) { $message.requestId } else { $null }
if (-not $message -or [string]::IsNullOrWhiteSpace([string]$requestId)) {
    Write-Warning 'Discarding malformed workflow start message'
    return
}

$existing = Get-DurableStatus -InstanceId $requestId
if ($existing -and $existing.RuntimeStatus -in @('Running', 'Pending')) {
    Write-Information "Orchestration $requestId already active; skipping duplicate start"
    return
}

Start-DurableOrchestration -FunctionName 'DecommissionOrchestrator' -InputObject $requestId -InstanceId $requestId | Out-Null
Write-Information "Scheduled orchestration $requestId"
