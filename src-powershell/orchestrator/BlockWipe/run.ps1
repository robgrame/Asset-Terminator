param($InputData, $TriggerMetadata)

# Activity: block the wipe (guardrail failure or incomplete pre-wipe actions), move the
# request to GuardrailsFailed, and publish the callback. Parity with
# DecommissionActivities.BlockWipe.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requestId = $InputData.RequestId
$reasons = @($InputData.Reasons)
$callbackEvent = Get-OptionalProp $InputData 'CallbackEvent'
if (-not $callbackEvent) { $callbackEvent = 'GuardrailsBlocked' }

$record = Get-DecommissionRequest -RequestId $requestId
if (-not $record) { throw "Request '$requestId' not found." }

$hasWipe = @(@($record.actions) | Where-Object { [string](Get-OptionalProp $_ 'Target') -eq 'Wipe' }).Count -gt 0
if ($hasWipe) {
    Set-ActionStatus -RequestId $requestId -Target 'Wipe' -Status 'Blocked' -FinalOutcome 'Blocked'
}
Set-RequestState -RequestId $requestId -State 'GuardrailsFailed'
Add-RequestAudit -Record $record -Action 'WipeBlocked' -Target 'Wipe' -Outcome 'Blocked' -Reason ($reasons -join '; ')

$record = Get-DecommissionRequest -RequestId $requestId
Publish-Callback -Record $record -EventType $callbackEvent
