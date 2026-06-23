# WipeProcessor - Service Bus trigger
# Reads a wipe request from the queue, resolves the Intune managed device,
# evaluates the guardrails and -- only if all mandatory guardrails pass --
# issues the Intune wipe (or simulates it when dryRun is set).

param($Message, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/Common.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/Guardrails.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/IntuneWipe.psm1" -Force

$guardrailConfigPath = Join-Path $PSScriptRoot '../config/guardrails.config.json'

# The Service Bus trigger may deliver the message as a string or a parsed object.
$request = $Message
if ($request -is [string]) { $request = $request | ConvertFrom-Json }

$logProps = @{
    correlationId   = $request.correlationId
    requestId       = $request.requestId
    managedDeviceId = $request.managedDeviceId
    deviceName      = $request.deviceName
    dryRun          = $request.dryRun
}

Write-PocLog -Level 'Information' -Message 'Processing wipe request.' -Properties $logProps

# --- 1. Resolve the device --------------------------------------------------
$device = Get-IntuneManagedDevice -ManagedDeviceId $request.managedDeviceId -DeviceName $request.deviceName
if (-not $device) {
    Write-PocLog -Level 'Error' -Message 'Device not found in Intune; nothing to wipe.' -Properties $logProps
    return
}

$logProps.managedDeviceId = $device.id

# --- 2. Evaluate guardrails -------------------------------------------------
$decision = Invoke-Guardrails -Device $device -ConfigPath $guardrailConfigPath

foreach ($r in $decision.Results) {
    Write-PocLog -Level ($r.Passed ? 'Information' : 'Warning') `
        -Message "Guardrail '$($r.Name)' [$($r.Mode)] -> $($r.Passed ? 'PASS' : 'FAIL'): $($r.Reason)" `
        -Properties $logProps
}

if (-not $decision.Allowed) {
    Write-PocLog -Level 'Warning' -Message "WIPE BLOCKED by guardrails: $($decision.BlockingReasons -join '; ')" -Properties $logProps
    return
}

# --- 3. Execute (or simulate) the wipe --------------------------------------
$dryRun = [bool]$request.dryRun
$result = Invoke-IntuneWipe -ManagedDeviceId $device.id -DryRun:$dryRun -LogProperties $logProps

Write-PocLog -Level 'Information' -Message "Wipe outcome: $($result.Outcome)." -Properties ($logProps + @{ outcome = $result.Outcome })
