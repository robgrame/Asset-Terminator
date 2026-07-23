param($RequestId, $TriggerMetadata)

# Activity: compute the overall request state from its actions, persist it, and publish
# the state-changed callback. If the request was already blocked, leave it for the
# override flow / poller. Parity with DecommissionActivities.Finalize.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$record = Get-DecommissionRequest -RequestId $RequestId
if (-not $record) { throw "Request '$RequestId' not found." }

if ([string](Get-OptionalProp $record 'State') -eq 'GuardrailsFailed') { return }

$state = Get-OverallState -Actions @($record.actions)
Set-RequestState -RequestId $RequestId -State $state
Add-RequestAudit -Record $record -Action 'StateChanged' -Outcome $state

$record = Get-DecommissionRequest -RequestId $RequestId
Publish-Callback -Record $record -EventType 'StateChanged'
