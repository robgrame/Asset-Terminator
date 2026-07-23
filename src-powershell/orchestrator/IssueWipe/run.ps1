param($RequestId, $TriggerMetadata)

# Activity: issue the Intune wipe. The wipe is asynchronous — success here only means
# the command was accepted; completion is reconciled by the polling engine.
# Parity with DecommissionActivities.IssueWipe.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$record = Get-DecommissionRequest -RequestId $RequestId
if (-not $record) { throw "Request '$RequestId' not found." }
$context = Get-StoredDeviceContext -Record $record
$dryRun = [bool](Get-OptionalProp $record 'DryRun')
$logProps = @{ requestId = $RequestId; target = 'Wipe' }

if ($dryRun) {
    Set-ActionStatus -RequestId $RequestId -Target 'Wipe' -Status 'Skipped' -FinalOutcome 'Skipped'
    Add-RequestAudit -Record $record -Action 'WipeSimulated' -Target 'Wipe' -Outcome 'Skipped' -Reason '[DRY-RUN]'
    return
}

$deviceId = Get-OptionalProp $context 'IntuneDeviceId'
if (-not $deviceId) {
    Set-ActionStatus -RequestId $RequestId -Target 'Wipe' -Status 'Failed' -FinalOutcome 'Failed'
    Add-RequestAudit -Record $record -Action 'WipeAccepted' -Target 'Wipe' -Outcome 'Failed' -Reason 'no Intune device to wipe'
    return
}

Add-RequestAudit -Record $record -Action 'WipeIssued' -Target 'Wipe' -Outcome 'InProgress'
try {
    $r = Invoke-IntuneWipe -ManagedDeviceId $deviceId -LogProperties $logProps
    Set-ActionStatus -RequestId $RequestId -Target 'Wipe' -Status 'InProgress'
    Add-RequestAudit -Record $record -Action 'WipeAccepted' -Target 'Wipe' -Outcome 'InProgress' -Reason "wipe $($r.Outcome); awaiting completion"
}
catch {
    Set-ActionStatus -RequestId $RequestId -Target 'Wipe' -Status 'Failed' -FinalOutcome 'Failed'
    Add-RequestAudit -Record $record -Action 'WipeAccepted' -Target 'Wipe' -Outcome 'Failed' -Reason $_.Exception.Message
}
