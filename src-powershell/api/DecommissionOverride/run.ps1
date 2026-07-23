using namespace System.Net

# DecommissionOverride — HTTP POST v1/decommission/{requestId}/override
# Parity with AssetTerminator.Api DecommissionOverrideFunction.
# Requires the Approver role and a mandatory reason. Records each approval
# immutably; once the required number of distinct approvers is reached, the
# workflow is re-queued so the orchestrator re-evaluates guardrails honoring
# the override.

param($Request, $TriggerMetadata)

$ingestion = Get-IngestionOptions
$deny = Test-HttpAuthGate -Request $Request -Config $ingestion
if ($deny) { Write-HttpJson -StatusCode $deny.StatusCode -Body @{ status = $deny.StatusCode; detail = $deny.Detail }; return }

$roles = Get-AppRoles
if (-not (Test-CallerInRole -Request $Request -Role $roles.Approver)) {
    Write-HttpJson -StatusCode 403 -Body @{ status = 403; detail = 'Approver role required.' }
    return
}

$requestId = [string]$Request.Params.requestId
$body = ConvertTo-RequestObject -Body $Request.Body
if (-not $body) { Write-HttpJson -StatusCode 400 -Body @{ status = 400; detail = 'Invalid JSON.' }; return }

$reason = Get-OptionalProp $body 'reason'
if ([string]::IsNullOrWhiteSpace($reason)) { Write-HttpJson -StatusCode 400 -Body @{ status = 400; detail = 'A non-empty reason is required.' }; return }
$guardrailIds = @(Get-OptionalProp $body 'guardrailIds')

try { $record = Get-DecommissionRequest -RequestId $requestId }
catch {
    Write-AtLog -Level 'Error' -Message "Override lookup failed: $($_.Exception.Message)" -Properties @{ requestId = $requestId }
    Write-HttpJson -StatusCode 500 -Body @{ status = 500; detail = 'Failed to read request state.' }
    return
}
if (-not $record) { Write-HttpJson -StatusCode 404 -Body @{ status = 404; detail = "Request '$requestId' not found." }; return }

$state = [string](Get-OptionalProp $record 'State')
if ($state -ne 'GuardrailsFailed') {
    Write-HttpJson -StatusCode 409 -Body @{ status = 409; detail = "Request is not in a blocked state (current: $state)." }
    return
}

$approver = Get-CallerUpn -Request $Request
$existing = @(Get-GuardrailOverride -RequestId $requestId)
if ($existing | Where-Object { [string]::Equals([string](Get-OptionalProp $_ 'ApproverUpn'), $approver, [StringComparison]::OrdinalIgnoreCase) }) {
    Write-HttpJson -StatusCode 409 -Body @{ status = 409; detail = 'This approver has already signed off.' }
    return
}

Add-GuardrailOverride -RequestId $requestId -ApproverUpn $approver -Reason $reason -GuardrailIds $guardrailIds

try {
    Add-AuditRecord -Record (New-AuditRecord -CorrelationId (Get-OptionalProp $record 'CorrelationId') -RequestId $requestId `
            -TicketNumber (Get-OptionalProp $record 'TicketNumber') -AssetId (Get-OptionalProp $record 'AssetId') `
            -Action 'GuardrailOverride' -Actor $approver -Outcome 'Approved' `
            -Reason "$reason | guardrails: $($guardrailIds -join ',')")
}
catch { Write-AtLog -Level 'Warning' -Message "Audit append failed: $($_.Exception.Message)" -Properties @{ requestId = $requestId } }

$approvals = $existing.Count + 1
$required = Get-OverrideRequiredFor -AssetCategory ([string](Get-OptionalProp $record 'AssetCategory'))
$applied = $approvals -ge $required

if ($applied) {
    Write-AtLog -Message "Override quorum reached for $requestId ($approvals/$required); re-queuing workflow" -Properties @{ requestId = $requestId }
    Set-RequestState -RequestId $requestId -State 'Validated'
    Start-DecommissionWorkflow -RequestId $requestId -CorrelationId (Get-OptionalProp $record 'CorrelationId')
}

Write-HttpJson -StatusCode 202 -Body @{ requestId = $requestId; approvals = $approvals; required = $required; applied = $applied }
