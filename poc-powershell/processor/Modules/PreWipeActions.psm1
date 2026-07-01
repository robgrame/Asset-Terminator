# PreWipeActions.psm1
# On-device preventive actions the full .NET solution runs BEFORE a wipe through
# the on-prem agent (AssetTerminator.Providers.DeviceActions):
#   * Enterprise -> Windows Pro license step-down
#   * OEM BIOS password removal (Dell/HP/Lenovo tooling)
#
# The POC is cloud-only: it has NO on-prem agent that can run code on the target
# device, so these steps are SIMULATED here. Each is config-gated and its outcome
# is logged + recorded to the state history exactly like a real step, so the
# end-to-end decommission flow stays tangible. In the full solution these are real
# on-device commands dispatched to the agent and awaited before the wipe.
#
# The engine mirrors the guardrail engine: config-driven, each action a small
# function, a registry mapping config name -> function.

function New-PreWipeResult {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][bool] $Succeeded,
        [string] $Detail,
        [bool] $Required = $true
    )
    [pscustomobject]@{
        Name      = $Name
        Succeeded = $Succeeded
        Required  = $Required
        Detail    = $Detail
    }
}

function Invoke-LicenseRemovalAction {
    <# Simulated Enterprise -> Windows Pro license step-down. #>
    param($Device, $Settings, [switch] $DryRun)

    $edition = if ($Settings.targetEdition) { [string]$Settings.targetEdition } else { 'Windows Pro' }
    $detail = if ($DryRun) {
        "DRY-RUN (simulated): would step the license down to '$edition'."
    }
    else {
        "Simulated: license stepped down to '$edition' (no on-prem agent in the POC)."
    }
    return New-PreWipeResult -Name 'LicenseRemoval' -Succeeded $true -Detail $detail
}

function Invoke-BiosPasswordRemovalAction {
    <# Simulated OEM BIOS password removal via the vendor tool. #>
    param($Device, $Settings, [switch] $DryRun)

    $vendor = if ($Device.manufacturer) { [string]$Device.manufacturer } else { 'OEM' }
    $detail = if ($DryRun) {
        "DRY-RUN (simulated): would remove the BIOS password using the $vendor tool."
    }
    else {
        "Simulated: BIOS password removed using the $vendor tool (no on-prem agent in the POC)."
    }
    return New-PreWipeResult -Name 'BiosPasswordRemoval' -Succeeded $true -Detail $detail
}

$script:PreWipeRegistry = @{
    'LicenseRemoval'      = 'Invoke-LicenseRemovalAction'
    'BiosPasswordRemoval' = 'Invoke-BiosPasswordRemovalAction'
}

function Invoke-PreWipeActions {
    <#
        .SYNOPSIS
            Runs every enabled pre-wipe preventive action against a device.
        .DESCRIPTION
            Reads config/prewipe.config.json. Each enabled action runs; when
            requireCompletionBeforeWipe is true a failed REQUIRED action blocks the
            wipe (Allowed = $false), mirroring RequireCompletionBeforeWipe of the
            full solution. Actions that throw are treated as a failure (fail-closed).
        .OUTPUTS
            PSCustomObject: Allowed (bool), Results (array), BlockingReasons (string[]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)][string] $ConfigPath,
        [switch] $DryRun
    )

    if (-not (Test-Path $ConfigPath)) {
        # No config => nothing to run; do not block the wipe.
        return [pscustomobject]@{ Allowed = $true; Results = @(); BlockingReasons = @() }
    }

    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    $requireCompletion = if ($null -ne $config.requireCompletionBeforeWipe) { [bool]$config.requireCompletionBeforeWipe } else { $true }
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($a in $config.actions) {
        if (-not $a.enabled) { continue }

        $fn = $script:PreWipeRegistry[$a.name]
        if (-not $fn) {
            Write-PocLog -Level 'Warning' -Message "Unknown pre-wipe action '$($a.name)' in config; skipped."
            continue
        }

        try {
            $result = & $fn -Device $Device -Settings $a.settings -DryRun:$DryRun
        }
        catch {
            $result = New-PreWipeResult -Name $a.name -Succeeded $false -Detail "Action error: $($_.Exception.Message)"
        }

        $required = if ($null -ne $a.required) { [bool]$a.required } else { $true }
        $result.Required = $required
        $results.Add($result) | Out-Null
    }

    $blocking = @()
    if ($requireCompletion) {
        $blocking = $results | Where-Object { -not $_.Succeeded -and $_.Required }
    }

    return [pscustomobject]@{
        Allowed         = ($blocking.Count -eq 0)
        Results         = $results
        BlockingReasons = @($blocking | ForEach-Object { "$($_.Name): $($_.Detail)" })
    }
}

Export-ModuleMember -Function Invoke-PreWipeActions, New-PreWipeResult,
    Invoke-LicenseRemovalAction, Invoke-BiosPasswordRemovalAction
