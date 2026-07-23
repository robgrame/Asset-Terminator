param($RequestId, $TriggerMetadata)

# Activity: enrich the device context (Intune + Entra + primary user), persist it,
# mark the request Validated, and return serializable metadata for the orchestrator.
# Parity with DecommissionActivities.EnrichAndValidate.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$record = Get-DecommissionRequest -RequestId $RequestId
if (-not $record) { throw "Request '$RequestId' not found." }

$context = Get-EnrichedDeviceContext -Record $record
Set-DeviceContextJson -RequestId $RequestId -DeviceContextJson ($context | ConvertTo-Json -Depth 10 -Compress)
Set-RequestState -RequestId $RequestId -State 'Validated'

$disposition = [string](Get-OptionalProp $record 'DispositionType')
Add-RequestAudit -Record $record -Action 'Validated' -Outcome 'Validated' `
    -Reason "disposition=$disposition; intuneId=$($context.IntuneDeviceId); entraId=$($context.EntraDeviceId); encrypted=$($context.isEncrypted)"

$targets = @(@($record.actions) | ForEach-Object { [string](Get-OptionalProp $_ 'Target') } | Where-Object { $_ })
$opts = Get-OrchestrationOptions

[pscustomobject]@{
    DryRun                     = [bool](Get-OptionalProp $record 'DryRun')
    Disposition                = $disposition
    Targets                    = $targets
    PreWipePollIntervalSeconds = $opts.PreWipePollIntervalSeconds
    RequirePreWipeCompletion   = $opts.RequireCompletionBeforeWipe
}
