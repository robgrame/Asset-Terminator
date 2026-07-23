param($RequestId, $TriggerMetadata)

# Activity: evaluate guardrails against the enriched device context, honouring approved
# overrides. An override with no explicit guardrail ids means "bypass all overridable
# blocks". Parity with DecommissionActivities.EvaluateGuardrails.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$record = Get-DecommissionRequest -RequestId $RequestId
if (-not $record) { throw "Request '$RequestId' not found." }
$context = Get-StoredDeviceContext -Record $record

$overrides = @(Get-GuardrailOverride -RequestId $RequestId)
$config = Get-GuardrailConfig

$bypassAll = $false
$overriddenIds = @()
foreach ($o in $overrides) {
    $raw = Get-OptionalProp $o 'GuardrailIds'
    $ids = @()
    if ($raw) { try { $ids = @($raw | ConvertFrom-Json) } catch { $ids = @() } }
    if (@($ids).Count -eq 0) { $bypassAll = $true } else { $overriddenIds += @($ids) }
}

if ($bypassAll) {
    # Bypass every overridable guardrail.
    $overriddenIds = @($config.guardrails | Where-Object { $_.overridable } | ForEach-Object { $_.name })
}
$overriddenIds = @($overriddenIds | Where-Object { $_ } | Select-Object -Unique)

$eval = Invoke-Guardrails -Device $context -Config $config -OverriddenGuardrails $overriddenIds
$allowed = [bool]$eval.Allowed
$blocking = @($eval.BlockingReasons)

Add-RequestAudit -Record $record -Action 'GuardrailsEvaluated' -Target 'Wipe' `
    -Outcome ($allowed ? 'Passed' : 'Blocked') `
    -Reason ($allowed ? $null : ($blocking -join '; ')) `
    -GuardrailResults $eval.Results

[pscustomobject]@{
    Allowed         = $allowed
    BlockingReasons = $blocking
}
