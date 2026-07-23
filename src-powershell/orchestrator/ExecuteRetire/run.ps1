param($RequestId, $TriggerMetadata)

# Activity: issue the Intune retire (re-purpose). Asynchronous — acceptance only.
# Parity with DecommissionActivities.ExecuteRetire.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$record = Get-DecommissionRequest -RequestId $RequestId
if (-not $record) { throw "Request '$RequestId' not found." }
$context = Get-StoredDeviceContext -Record $record
$dryRun = [bool](Get-OptionalProp $record 'DryRun')
$logProps = @{ requestId = $RequestId; target = 'Retire' }

if ($dryRun) {
    Set-ActionStatus -RequestId $RequestId -Target 'Retire' -Status 'Skipped' -FinalOutcome 'Skipped'
    Add-RequestAudit -Record $record -Action 'RetireSimulated' -Target 'Retire' -Outcome 'Skipped' -Reason '[DRY-RUN]'
    return
}

$deviceId = Get-OptionalProp $context 'IntuneDeviceId'
if (-not $deviceId) {
    Set-ActionStatus -RequestId $RequestId -Target 'Retire' -Status 'Skipped' -FinalOutcome 'Skipped'
    Add-RequestAudit -Record $record -Action 'RetireAccepted' -Target 'Retire' -Outcome 'Skipped' -Reason 'no Intune device to retire'
    return
}

Add-RequestAudit -Record $record -Action 'RetireIssued' -Target 'Retire' -Outcome 'InProgress'
try {
    $r = Invoke-IntuneRetire -ManagedDeviceId $deviceId -LogProperties $logProps
    Set-ActionStatus -RequestId $RequestId -Target 'Retire' -Status 'InProgress'
    Add-RequestAudit -Record $record -Action 'RetireAccepted' -Target 'Retire' -Outcome 'InProgress' -Reason "retire $($r.Outcome); awaiting completion"
}
catch {
    Set-ActionStatus -RequestId $RequestId -Target 'Retire' -Status 'Failed' -FinalOutcome 'Failed'
    Add-RequestAudit -Record $record -Action 'RetireAccepted' -Target 'Retire' -Outcome 'Failed' -Reason $_.Exception.Message
}
