# WipeProcessor - Service Bus trigger (Processor Function App, internal)
# Reads a wipe request from the queue, resolves the Intune managed device,
# evaluates the guardrails and -- only if all mandatory guardrails pass --
# issues the Intune wipe (or simulates it when dryRun is set). Every state
# transition is persisted to the Table Storage state store for tracking.
#
# This app holds the privileged Microsoft Graph permissions; it is not exposed
# to the internet (no HTTP trigger).

param($Message, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/Common.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/Guardrails.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/IntuneWipe.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/StateStore.psm1" -Force

$guardrailConfigPath = Join-Path $PSScriptRoot '../config/guardrails.config.json'

# The Service Bus trigger may deliver the message as a string or a parsed object.
$request = $Message
if ($request -is [string]) { $request = $request | ConvertFrom-Json }

$logProps = @{
    correlationId   = $request.correlationId
    requestId       = $request.requestId
    managedDeviceId = $request.managedDeviceId
    deviceName      = $request.deviceName
    serialNumber    = $request.serialNumber
    dryRun          = $request.dryRun
}

function Update-State {
    param([string] $Status, [string] $Detail)
    try {
        Set-DecommissionState -RequestId $request.requestId -Status $Status -Properties @{
            CorrelationId = [string]$request.correlationId
            Detail        = [string]$Detail
        }
    }
    catch {
        Write-PocLog -Level 'Warning' -Message "Could not update state to '$Status': $($_.Exception.Message)" -Properties $logProps
    }
}

Write-PocLog -Level 'Information' -Message 'Processing wipe request.' -Properties $logProps
Update-State -Status 'InProgress' -Detail 'Resolving device and evaluating guardrails.'

try {
    # --- 1. Resolve the device ----------------------------------------------
    # ServiceNow sends serialNumber + deviceName. When several stale objects match,
    # Get-IntuneManagedDevice selects the freshest (newest enrollment / check-in).
    $device = Get-IntuneManagedDevice -ManagedDeviceId $request.managedDeviceId `
        -DeviceName $request.deviceName -SerialNumber $request.serialNumber -LogProperties $logProps
    if (-not $device) {
        Write-PocLog -Level 'Error' -Message 'Device not found in Intune; nothing to wipe.' -Properties $logProps
        Update-State -Status 'Failed' -Detail 'Device not found in Intune.'
        return
    }

    $logProps.managedDeviceId = $device.id
    $logProps.resolvedSerial  = $device.serialNumber
    $logProps.enrolledDateTime = $device.enrolledDateTime
    $logProps.lastSyncDateTime = $device.lastSyncDateTime

    # --- 2. Evaluate guardrails ---------------------------------------------
    $decision = Invoke-Guardrails -Device $device -ConfigPath $guardrailConfigPath

    foreach ($r in $decision.Results) {
        Write-PocLog -Level ($r.Passed ? 'Information' : 'Warning') `
            -Message "Guardrail '$($r.Name)' [$($r.Mode)] -> $($r.Passed ? 'PASS' : 'FAIL'): $($r.Reason)" `
            -Properties $logProps
    }

    if (-not $decision.Allowed) {
        $reasons = $decision.BlockingReasons -join '; '
        Write-PocLog -Level 'Warning' -Message "WIPE BLOCKED by guardrails: $reasons" -Properties $logProps
        Update-State -Status 'Blocked' -Detail "Guardrails blocked the wipe: $reasons"
        return
    }

    # --- 3. Execute (or simulate) the wipe ----------------------------------
    $dryRun = [bool]$request.dryRun
    $result = Invoke-IntuneWipe -ManagedDeviceId $device.id -DryRun:$dryRun -LogProperties $logProps
    Write-PocLog -Level 'Information' -Message "Wipe outcome: $($result.Outcome)." -Properties ($logProps + @{ outcome = $result.Outcome })

    $status = if ($dryRun) { 'Completed' } else { 'InProgress' }
    $detail = if ($dryRun) { 'Dry-run completed; no wipe issued.' } else { 'Wipe command issued; awaiting device check-in.' }
    Update-State -Status $status -Detail $detail
}
catch {
    Write-PocLog -Level 'Error' -Message "Processing failed: $($_.Exception.Message)" -Properties $logProps
    Update-State -Status 'Failed' -Detail "Processing failed: $($_.Exception.Message)"
    throw  # let Service Bus retry / dead-letter
}

