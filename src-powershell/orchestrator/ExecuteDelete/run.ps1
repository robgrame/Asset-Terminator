param($InputData, $TriggerMetadata)

# Activity: perform (or dispatch) an object-delete / pre-wipe preventive action for a
# single target. Cloud targets are executed here; on-prem targets are dispatched to the
# self-hosted agent via the on-prem queue. Parity with DecommissionActivities.ExecuteDelete.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requestId = $InputData.RequestId
$target = $InputData.Target

$record = Get-DecommissionRequest -RequestId $requestId
if (-not $record) { throw "Request '$requestId' not found." }
$dryRun = [bool](Get-OptionalProp $record 'DryRun')
$logProps = @{ requestId = $requestId; target = $target }

if ($dryRun) {
    Set-ActionStatus -RequestId $requestId -Target $target -Status 'Skipped' -FinalOutcome 'Skipped'
    Add-RequestAudit -Record $record -Action 'DeleteSimulated' -Target $target -Outcome 'Skipped' -Reason '[DRY-RUN]'
    return
}

if (Test-IsOnPremDeleteTarget -Target $target) {
    # On-prem deletes are executed by the self-hosted agent via the on-prem queue.
    Set-ActionStatus -RequestId $requestId -Target $target -Status 'InProgress'
    Send-ActionDispatch -RequestId $requestId -Target $target
    Add-RequestAudit -Record $record -Action 'DeleteDispatched' -Target $target -Outcome 'InProgress' -Reason 'queued for on-prem agent'
    return
}

$context = Get-StoredDeviceContext -Record $record
Add-RequestAudit -Record $record -Action 'DeleteAttempted' -Target $target -Outcome 'InProgress'

$result = Invoke-CloudDelete -Target $target -Context $context -LogProperties $logProps
$update = Get-ActionUpdateFromResult -Result $result
Set-ActionStatus -RequestId $requestId -Target $target -Status $update.Status -FinalOutcome $update.FinalOutcome
Add-RequestAudit -Record $record -Action 'DeleteCompleted' -Target $target -Outcome $update.Status -Reason $result.Detail
