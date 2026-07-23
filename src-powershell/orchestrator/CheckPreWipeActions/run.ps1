param($InputData, $TriggerMetadata)

# Activity: report completion of the on-device pre-wipe preventive actions, plus whether
# the request deadline has passed. Parity with DecommissionActivities.CheckPreWipeActions.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requestId = $InputData.RequestId
$targetSet = @($InputData.Targets)

$record = Get-DecommissionRequest -RequestId $requestId
if (-not $record) { throw "Request '$requestId' not found." }

$actions = @(@($record.actions) | Where-Object { [string](Get-OptionalProp $_ 'Target') -in $targetSet })

$params = @{ Actions = $actions }
$dueAt = Get-OptionalProp $record 'DueAtUtc'
if ($dueAt) { $params['DueAtUtc'] = [datetime]$dueAt }

Get-PreWipeStatus @params
