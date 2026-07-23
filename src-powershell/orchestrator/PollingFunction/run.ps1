param($Timer)

# Timer-triggered reconciliation engine. Periodically re-checks every active decommission
# request: verifies real provider/wipe state, applies retry-with-backoff, enforces the SLA
# and the give-up timeout, and pushes ServiceNow callbacks. The schedule is configurable via
# AssetTerminator__Orchestration__PollingCron. Parity with PollingFunction + ReconciliationService.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isPastDue = $false
if ($Timer -and $Timer.PSObject.Properties['IsPastDue']) { $isPastDue = [bool]$Timer.IsPastDue }
Write-AtLog -Message "Reconciliation tick (past due: $isPastDue)"

try {
    Invoke-ReconcileAll -Max 200
}
catch {
    Write-AtLog -Level 'Error' -Message "Reconciliation tick failed: $($_.Exception.Message)"
    throw
}
