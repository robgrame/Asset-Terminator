# AT.Guardrails.psm1
# Extensible, config-driven guardrail engine. Parity with AssetTerminator.Guardrails
# (IWipeGuardrail + GuardrailEngine) and the PoC engine, extended with the override
# hook of the full solution.
#
# HOW IT WORKS
#   * Each guardrail is a function: Test-<Name>Guardrail -Device -Settings -> result
#     object { Name, Passed, Severity, Reason }.
#   * $GuardrailRegistry maps a config "name" to its function.
#   * Invoke-Guardrails runs every ENABLED guardrail and BLOCKS when any 'Mandatory'
#     guardrail fails, UNLESS it is 'Overridable' and covered by an approved override.
#     'Warning' guardrails are reported but never block. A guardrail that throws is
#     treated as a blocking failure (fail-closed).
#
# ADD A NEW GUARDRAIL: write Test-<Name>Guardrail, register it, add a config entry.

Set-StrictMode -Version Latest

function New-GuardrailResult {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][bool] $Passed,
        [ValidateSet('Blocking', 'Warning', 'Info')][string] $Severity = 'Blocking',
        [string] $Reason
    )
    [pscustomobject]@{ Name = $Name; Passed = $Passed; Severity = $Severity; Reason = $Reason }
}

# --- Built-in guardrails (parity with the .NET rules) ---

function Get-DeviceSignal {
    <# StrictMode-safe optional device-property read (returns $null when absent). #>
    param($Device, [Parameter(Mandatory)][string] $Name)
    if ($Device -and $Device.PSObject.Properties[$Name]) { return $Device.$Name }
    return $null
}

function Test-EncryptionGuardrail {
    <#
        Device disk must be encrypted. Parity with EncryptionGuardrail.cs:
        device-type aware, fails closed on unknown state, and (Windows only) accepts an
        escrowed BitLocker recovery key as an equivalent to on-disk encryption.
    #>
    param($Device, $Settings)
    $type = [string](Get-DeviceSignal $Device 'DeviceType')
    if ([string]::IsNullOrWhiteSpace($type)) { $type = 'Windows' }
    $isEnc = Get-DeviceSignal $Device 'isEncrypted'              # $null / $true / $false
    $escrow = Get-DeviceSignal $Device 'hasRecoveryKeyEscrowed'  # $null / $true / $false

    switch -Regex ($type) {
        '^windows$' {
            if ($null -eq $isEnc) {
                return New-GuardrailResult -Name 'Encryption' -Passed $false -Severity 'Blocking' -Reason 'Windows encryption state is unknown; failing closed.'
            }
            $passed = ([bool]$isEnc) -or ([bool]$escrow)
            return New-GuardrailResult -Name 'Encryption' -Passed $passed -Severity 'Blocking' -Reason (
                $(if ($passed) { 'Windows device is encrypted (or a BitLocker recovery key is escrowed).' }
                  else { 'Windows device is not encrypted and no BitLocker recovery key is escrowed.' }))
        }
        '^macos$' {
            if ($null -eq $isEnc) {
                return New-GuardrailResult -Name 'Encryption' -Passed $false -Severity 'Blocking' -Reason 'macOS FileVault state is unknown; failing closed.'
            }
            return New-GuardrailResult -Name 'Encryption' -Passed ([bool]$isEnc) -Severity 'Blocking' -Reason (
                $(if ([bool]$isEnc) { 'macOS device has FileVault enabled.' } else { 'macOS device does not have FileVault enabled.' }))
        }
        '^(ios|android)$' {
            return New-GuardrailResult -Name 'Encryption' -Passed $true -Severity 'Info' -Reason "Encryption is enforced by the platform on '$type'."
        }
        default {
            return New-GuardrailResult -Name 'Encryption' -Passed $false -Severity 'Blocking' -Reason "Encryption state for device type '$type' cannot be evaluated."
        }
    }
}

function Test-InactivityGuardrail {
    <#
        Device must have been inactive for at least N days before wipe. Parity with
        InactivityGuardrail.cs: unknown last activity fails closed; the default
        threshold is 30 days.
    #>
    param($Device, $Settings)
    $minDays = 30
    if ($Settings -and $Settings.PSObject.Properties['minimumInactiveDays'] -and $Settings.minimumInactiveDays) {
        $minDays = [int]$Settings.minimumInactiveDays
    }
    $last = Get-DeviceSignal $Device 'lastSyncDateTime'
    if (-not $last) {
        return New-GuardrailResult -Name 'Inactivity' -Passed $false -Severity 'Blocking' -Reason 'Last activity is unknown; failing closed.'
    }
    $days = (New-TimeSpan -Start ([datetime]$last) -End ([datetime]::UtcNow)).TotalDays
    $passed = $days -ge $minDays
    New-GuardrailResult -Name 'Inactivity' -Passed $passed -Severity 'Blocking' -Reason (
        $(if ($passed) { "Last activity {0:N1} days ago (>= {1}-day threshold)." -f $days, $minDays }
          else { "Device was active too recently: last activity {0:N1} days ago is within the {1}-day inactivity threshold." -f $days, $minDays }))
}

function Test-CriticalGroupGuardrail {
    <#
        Device must NOT belong to a blocked group. Parity with CriticalGroupGuardrail.cs:
        blocks when any Entra group membership matches the configured BlockedGroups.
        As a PowerShell-specific extension it additionally blocks on the Intune device
        category (which the enricher populates), using the same blocked set.
    #>
    param($Device, $Settings)
    $blocked = @()
    if ($Settings) {
        foreach ($prop in 'BlockedGroups', 'blockedGroups', 'blockedCategories') {
            if ($Settings.PSObject.Properties[$prop] -and $Settings.$prop) {
                $val = $Settings.$prop
                if ($val -is [string]) { $blocked += @($val -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                else { $blocked += @($val) }
            }
        }
    }
    $blocked = @($blocked | Where-Object { $_ } | Select-Object -Unique)

    # Parity: match Entra group memberships.
    $memberships = @(Get-DeviceSignal $Device 'groupMemberships') | Where-Object { $_ }
    $matchGroup = $memberships | Where-Object { $blocked -contains $_ } | Select-Object -First 1
    if ($matchGroup) {
        return New-GuardrailResult -Name 'CriticalGroup' -Passed $false -Severity 'Blocking' -Reason "Device belongs to blocked group '$matchGroup'."
    }

    # PowerShell extension: also block on the Intune device category.
    $category = Get-DeviceSignal $Device 'deviceCategoryDisplayName'
    if ($category -and ($blocked -contains $category)) {
        return New-GuardrailResult -Name 'CriticalGroup' -Passed $false -Severity 'Blocking' -Reason "Device belongs to blocked category '$category'."
    }

    New-GuardrailResult -Name 'CriticalGroup' -Passed $true -Severity 'Blocking' -Reason 'Device is not in any blocked group or category.'
}

$script:GuardrailRegistry = @{
    'Encryption'     = 'Test-EncryptionGuardrail'
    'Inactivity'     = 'Test-InactivityGuardrail'
    'CriticalGroup'  = 'Test-CriticalGroupGuardrail'
    # Back-compat alias with the PoC naming.
    'CriticalDevice' = 'Test-CriticalGroupGuardrail'
}

function Register-Guardrail {
    <#
        .SYNOPSIS
            Registers a custom guardrail (config name -> function) without recompiling.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Function)
    $script:GuardrailRegistry[$Name] = $Function
}

function Invoke-Guardrails {
    <#
        .SYNOPSIS
            Evaluates every enabled guardrail against a device and returns a decision.
        .PARAMETER Config
            Parsed config object (with a .guardrails array) OR use -ConfigPath.
        .PARAMETER OverriddenGuardrails
            Names of guardrails covered by an approved override; an Overridable
            Mandatory failure for one of these does not block.
        .OUTPUTS
            PSCustomObject: Allowed, Results, BlockingReasons, OverriddenReasons.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory)] $Device,
        [Parameter(Mandatory, ParameterSetName = 'Path')][string] $ConfigPath,
        [Parameter(Mandatory, ParameterSetName = 'Object')] $Config,
        [string[]] $OverriddenGuardrails = @()
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path $ConfigPath)) { throw "Guardrail config not found at '$ConfigPath'." }
        $Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    }

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($g in $Config.guardrails) {
        if (-not $g.enabled) { continue }
        $fn = $script:GuardrailRegistry[$g.name]
        if (-not $fn) {
            Write-AtLog -Level 'Warning' -Message "Unknown guardrail '$($g.name)' in config; skipped."
            continue
        }
        try {
            $settings = if ($g.PSObject.Properties['settings']) { $g.settings } else { $null }
            $result = & $fn -Device $Device -Settings $settings
        }
        catch {
            $result = New-GuardrailResult -Name $g.name -Passed $false -Severity 'Blocking' -Reason "Guardrail evaluation error: $($_.Exception.Message)"
        }

        $mode = if ($g.PSObject.Properties['mode'] -and $g.mode) { [string]$g.mode } else { 'Mandatory' }
        $overridable = -not ($g.PSObject.Properties['overridable'] -and -not $g.overridable)  # default: overridable
        $result | Add-Member -NotePropertyName 'Mode' -NotePropertyValue $mode -Force
        $result | Add-Member -NotePropertyName 'Overridable' -NotePropertyValue $overridable -Force
        $results.Add($result) | Out-Null
    }

    $failedMandatory = $results | Where-Object { -not $_.Passed -and $_.Mode -eq 'Mandatory' }
    $overridden = $failedMandatory | Where-Object { $_.Overridable -and ($OverriddenGuardrails -contains $_.Name) }
    $blocking   = $failedMandatory | Where-Object { -not ($_.Overridable -and ($OverriddenGuardrails -contains $_.Name)) }

    [pscustomobject]@{
        Allowed          = ($blocking | Measure-Object).Count -eq 0
        Results          = $results
        BlockingReasons  = @($blocking  | ForEach-Object { "$($_.Name): $($_.Reason)" })
        OverriddenReasons = @($overridden | ForEach-Object { "$($_.Name): $($_.Reason)" })
    }
}

Export-ModuleMember -Function New-GuardrailResult, Register-Guardrail, Invoke-Guardrails, `
    Test-EncryptionGuardrail, Test-InactivityGuardrail, Test-CriticalGroupGuardrail
