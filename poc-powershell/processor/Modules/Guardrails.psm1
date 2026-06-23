# Guardrails.psm1
# Extensible, config-driven guardrail engine for the wipe POC.
#
# HOW IT WORKS
#   * Each guardrail is a PowerShell function with the convention:
#         Test-<Name>Guardrail -Device <obj> -Settings <obj> -> [GuardrailResult]
#     returning a standard object: Name, Passed, Severity, Reason.
#   * The registry ($GuardrailRegistry) maps a config "name" to its function.
#   * Invoke-Guardrails reads config/guardrails.config.json, runs every ENABLED
#     guardrail, and BLOCKS the wipe if any guardrail with mode "Mandatory" fails.
#     "Warning" guardrails are reported but never block.
#
# ADD A NEW GUARDRAIL (no recompilation, mirrors the .NET IWipeGuardrail pattern):
#   1. Write a Test-<Name>Guardrail function below.
#   2. Add it to $GuardrailRegistry.
#   3. Add a { "name": "<Name>", "enabled": true, "mode": "Mandatory|Warning", "settings": {...} }
#      entry to config/guardrails.config.json.

function New-GuardrailResult {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][bool] $Passed,
        [ValidateSet('Blocking', 'Warning', 'Info')][string] $Severity = 'Blocking',
        [string] $Reason
    )
    [pscustomobject]@{
        Name     = $Name
        Passed   = $Passed
        Severity = $Severity
        Reason   = $Reason
    }
}

# ---------------------------------------------------------------------------
# Built-in guardrails
# ---------------------------------------------------------------------------

function Test-EncryptionGuardrail {
    <# Device disk must be encrypted (Windows BitLocker / macOS FileVault). #>
    param($Device, $Settings)

    $encrypted = [bool]$Device.isEncrypted
    return New-GuardrailResult -Name 'Encryption' -Passed $encrypted -Severity 'Blocking' -Reason (
        $encrypted ? 'Device is encrypted.' : 'Device is NOT encrypted (BitLocker/FileVault off).'
    )
}

function Test-InactivityGuardrail {
    <# Device must have been inactive for at least N days before wipe. #>
    param($Device, $Settings)

    $minDays = [int]($Settings.minimumInactiveDays ?? 14)
    if (-not $Device.lastSyncDateTime) {
        return New-GuardrailResult -Name 'Inactivity' -Passed $true -Severity 'Warning' -Reason 'No lastSyncDateTime available; treated as inactive.'
    }

    $days = (New-TimeSpan -Start ([datetime]$Device.lastSyncDateTime) -End (Get-Date).ToUniversalTime()).TotalDays
    $passed = $days -ge $minDays
    return New-GuardrailResult -Name 'Inactivity' -Passed $passed -Severity 'Warning' -Reason (
        "Last sync {0:N1} days ago (requires >= {1})." -f $days, $minDays
    )
}

function Test-CriticalDeviceGuardrail {
    <# Device must NOT belong to a blocked Intune device category. #>
    param($Device, $Settings)

    $blocked = @($Settings.blockedCategories)
    $category = $Device.deviceCategoryDisplayName
    $isBlocked = $category -and ($blocked -contains $category)
    $passed = -not $isBlocked
    return New-GuardrailResult -Name 'CriticalDevice' -Passed $passed -Severity 'Blocking' -Reason (
        $isBlocked ? "Device belongs to blocked category '$category'." : "Device category '$category' is not blocked."
    )
}

# ---------------------------------------------------------------------------
# Registry: config name -> implementing function
# ---------------------------------------------------------------------------

$script:GuardrailRegistry = @{
    'Encryption'     = 'Test-EncryptionGuardrail'
    'Inactivity'     = 'Test-InactivityGuardrail'
    'CriticalDevice' = 'Test-CriticalDeviceGuardrail'
}

function Invoke-Guardrails {
    <#
        .SYNOPSIS
            Evaluates every enabled guardrail against a device and returns a decision.
        .OUTPUTS
            PSCustomObject: Allowed (bool), Results (array), BlockingReasons (string[]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory)][string] $ConfigPath
    )

    if (-not (Test-Path $ConfigPath)) {
        throw "Guardrail config not found at '$ConfigPath'."
    }

    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($g in $config.guardrails) {
        if (-not $g.enabled) { continue }

        $fn = $script:GuardrailRegistry[$g.name]
        if (-not $fn) {
            Write-PocLog -Level 'Warning' -Message "Unknown guardrail '$($g.name)' in config; skipped."
            continue
        }

        try {
            $result = & $fn -Device $Device -Settings $g.settings
        }
        catch {
            # Fail closed: a guardrail that errors is treated as a blocking failure.
            $result = New-GuardrailResult -Name $g.name -Passed $false -Severity 'Blocking' -Reason "Guardrail evaluation error: $($_.Exception.Message)"
        }

        $mode = if ($g.mode) { [string]$g.mode } else { 'Mandatory' }
        $result | Add-Member -NotePropertyName 'Mode' -NotePropertyValue $mode -Force
        $results.Add($result) | Out-Null
    }

    $blocking = $results | Where-Object { -not $_.Passed -and $_.Mode -eq 'Mandatory' }

    return [pscustomobject]@{
        Allowed         = ($blocking.Count -eq 0)
        Results         = $results
        BlockingReasons = @($blocking | ForEach-Object { "$($_.Name): $($_.Reason)" })
    }
}

Export-ModuleMember -Function Invoke-Guardrails, New-GuardrailResult,
    Test-EncryptionGuardrail, Test-InactivityGuardrail, Test-CriticalDeviceGuardrail
