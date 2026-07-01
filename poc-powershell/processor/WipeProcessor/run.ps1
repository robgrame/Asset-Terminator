# WipeProcessor - Service Bus trigger (Processor Function App, internal)
# Reads a decommission request from the queue, resolves the Intune managed device
# and executes the flow for the request's dispositionType:
#
#   * Terminate (default): delete the device from Windows Autopilot, run the
#     config-gated pre-wipe preventive actions (Enterprise->Pro license step-down,
#     OEM BIOS password removal) and -- only if all mandatory guardrails and the
#     required preventive actions pass -- issue the Intune wipe.
#   * Retire (re-purpose): issue the Intune retire action; no wipe, no Autopilot
#     delete, no preventive actions.
#
# Everything is simulated when dryRun is set. Every state transition is persisted
# to the Table Storage state store for tracking.
#
# This app holds the privileged Microsoft Graph permissions; it is not exposed
# to the internet (no HTTP trigger).

param($Message, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/Common.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/Guardrails.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/IntuneWipe.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/IntuneActions.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/PreWipeActions.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/StateStore.psm1" -Force

$guardrailConfigPath = Join-Path $PSScriptRoot '../config/guardrails.config.json'
$preWipeConfigPath   = Join-Path $PSScriptRoot '../config/prewipe.config.json'

# The Service Bus trigger may deliver the message as a string or a parsed object.
$request = $Message
if ($request -is [string]) { $request = $request | ConvertFrom-Json }

# Disposition: Terminate (default) or Retire.
$disposition = if ($request.dispositionType) { [string]$request.dispositionType } else { 'Terminate' }
$dryRun = [bool]$request.dryRun

$logProps = @{
    correlationId   = $request.correlationId
    requestId       = $request.requestId
    managedDeviceId = $request.managedDeviceId
    deviceName      = $request.deviceName
    serialNumber    = $request.serialNumber
    dispositionType = $disposition
    dryRun          = $dryRun
}

function Update-State {
    param([string] $Status, [string] $Detail)
    try {
        Set-DecommissionState -RequestId $request.requestId -Status $Status -Properties @{
            CorrelationId   = [string]$request.correlationId
            DispositionType = [string]$disposition
            Detail          = [string]$Detail
        }
    }
    catch {
        Write-PocLog -Level 'Warning' -Message "Could not update state to '$Status': $($_.Exception.Message)" -Properties $logProps
    }
}

Write-PocLog -Level 'Information' -Message "Processing $disposition request." -Properties $logProps
Update-State -Status 'InProgress' -Detail "Resolving device for $disposition disposition."

try {
    # --- 1. Resolve the device ----------------------------------------------
    # ServiceNow sends serialNumber + deviceName. When several stale objects match,
    # Get-IntuneManagedDevice selects the freshest (newest enrollment / check-in).
    $device = Get-IntuneManagedDevice -ManagedDeviceId $request.managedDeviceId `
        -DeviceName $request.deviceName -SerialNumber $request.serialNumber -LogProperties $logProps
    if (-not $device) {
        Write-PocLog -Level 'Error' -Message 'Device not found in Intune; nothing to do.' -Properties $logProps
        Update-State -Status 'Failed' -Detail 'Device not found in Intune.'
        return
    }

    $logProps.managedDeviceId  = $device.id
    $logProps.resolvedSerial   = $device.serialNumber
    $logProps.enrolledDateTime = $device.enrolledDateTime
    $logProps.lastSyncDateTime = $device.lastSyncDateTime

    # --- Retire disposition (re-purpose): retire only, no wipe --------------
    if ($disposition -eq 'Retire') {
        $retire = Invoke-IntuneRetire -ManagedDeviceId $device.id -DryRun:$dryRun -LogProperties $logProps
        Write-PocLog -Level 'Information' -Message "Retire outcome: $($retire.Outcome)." -Properties ($logProps + @{ outcome = $retire.Outcome })
        $status = if ($dryRun) { 'Completed' } else { 'InProgress' }
        $detail = if ($dryRun) { 'Dry-run completed; no retire issued.' } else { 'Retire command issued; awaiting unenrollment.' }
        Update-State -Status $status -Detail $detail
        return
    }

    # --- Terminate disposition (destructive) --------------------------------
    # --- 2. Evaluate guardrails (gate the wipe) -----------------------------
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

    # --- 3. Pre-wipe: delete from Autopilot ---------------------------------
    $preWipeConfig = if (Test-Path $preWipeConfigPath) { Get-Content -Path $preWipeConfigPath -Raw | ConvertFrom-Json } else { $null }
    $deleteFromAutopilot = -not $preWipeConfig -or ($null -eq $preWipeConfig.deleteFromAutopilot) -or [bool]$preWipeConfig.deleteFromAutopilot

    if ($deleteFromAutopilot -and $request.serialNumber) {
        $ap = Remove-AutopilotDevice -SerialNumber $request.serialNumber -DryRun:$dryRun -LogProperties $logProps
        Update-State -Status 'InProgress' -Detail "Autopilot: $($ap.Outcome) - $($ap.Detail)"
    }

    # --- 4. Pre-wipe: preventive on-device actions (license / BIOS) ---------
    $preWipe = Invoke-PreWipeActions -Device $device -ConfigPath $preWipeConfigPath -DryRun:$dryRun
    foreach ($r in $preWipe.Results) {
        Write-PocLog -Level ($r.Succeeded ? 'Information' : 'Warning') `
            -Message "Pre-wipe action '$($r.Name)' [$($r.Required ? 'Required' : 'Optional')] -> $($r.Succeeded ? 'OK' : 'FAILED'): $($r.Detail)" `
            -Properties $logProps
    }

    if (-not $preWipe.Allowed) {
        $reasons = $preWipe.BlockingReasons -join '; '
        Write-PocLog -Level 'Warning' -Message "WIPE BLOCKED: required pre-wipe actions did not complete: $reasons" -Properties $logProps
        Update-State -Status 'Blocked' -Detail "Pre-wipe actions blocked the wipe: $reasons"
        return
    }

    # --- 5. Execute (or simulate) the wipe ----------------------------------
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
