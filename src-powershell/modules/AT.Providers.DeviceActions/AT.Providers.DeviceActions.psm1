# AT.Providers.DeviceActions.psm1
# On-device pre-wipe preventive actions executed by the on-prem agent:
#   * Enterprise (E3/E5) license removal -> step-down to Windows Pro
#   * BIOS/UEFI supervisor password removal via the OEM tool
# Parity with AssetTerminator.Providers.DeviceActions (LicenseRemovalProvider,
# BiosPasswordRemovalProvider, ProcessCommandRunner). Destructive calls honour -DryRun.

Set-StrictMode -Version Latest

function Expand-CommandTemplate {
    <# Applies the {serialNumber}/{deviceName}/{primaryUserUpn} placeholder substitutions. #>
    [CmdletBinding()]
    param([string] $Template, [Parameter(Mandatory)] $Context)
    if ([string]::IsNullOrEmpty($Template)) { return '' }
    $ci = [System.StringComparison]::OrdinalIgnoreCase
    $out = $Template
    $out = $out.Replace('{serialNumber}', [string](Get-OptionalProp $Context 'SerialNumber'), $ci)
    $out = $out.Replace('{deviceName}', [string](Get-OptionalProp $Context 'DeviceName'), $ci)
    $out = $out.Replace('{primaryUserUpn}', [string](Get-OptionalProp $Context 'PrimaryUserUpn'), $ci)
    return $out
}

function Test-CommandSpecConfigured {
    <# A spec is configured when it has a non-empty FileName. Parity with CommandSpec.IsConfigured. #>
    [CmdletBinding()]
    param($Spec)
    if ($null -eq $Spec) { return $false }
    $fileName = Get-OptionalProp $Spec 'FileName'
    return -not [string]::IsNullOrWhiteSpace([string]$fileName)
}

function Invoke-LocalCommand {
    <#
        .SYNOPSIS
            Launches a local executable/tool, applies placeholder substitution, enforces a timeout
            and captures stdout+stderr. Parity with ProcessCommandRunner.RunAsync.
        .OUTPUTS
            @{ Success; ExitCode; Output; TimedOut }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Spec, [Parameter(Mandatory)] $Context, [int] $TimeoutSeconds = 300)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = [string](Get-OptionalProp $Spec 'FileName')
    $psi.Arguments = Expand-CommandTemplate -Template ([string](Get-OptionalProp $Spec 'Arguments')) -Context $Context
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $wd = Get-OptionalProp $Spec 'WorkingDirectory'
    if (-not [string]::IsNullOrWhiteSpace([string]$wd)) { $psi.WorkingDirectory = [string]$wd }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { if (-not $proc.HasExited) { $proc.Kill($true) } } catch { }
            return @{ Success = $false; ExitCode = -1; Output = ($stdout.Result + $stderr.Result); TimedOut = $true }
        }
        $proc.WaitForExit()
        $output = ($stdout.Result + $stderr.Result)
        $ignore = [bool](Get-OptionalProp $Spec 'IgnoreExitCode')
        $success = ($proc.ExitCode -eq 0) -or $ignore
        return @{ Success = $success; ExitCode = $proc.ExitCode; Output = $output; TimedOut = $false }
    }
    finally { $proc.Dispose() }
}

function Resolve-DeviceManufacturer {
    <# Reads the 'Manufacturer' signal, falling back to a default. Parity with BiosPasswordRemovalProvider.ResolveManufacturer. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [string] $DefaultManufacturer)
    $signals = Get-OptionalProp $Context 'Signals'
    $value = $null
    if ($null -ne $signals) {
        if ($signals -is [System.Collections.IDictionary]) {
            foreach ($k in $signals.Keys) { if ([string]$k -ieq 'Manufacturer') { $value = $signals[$k]; break } }
        }
        else { $value = Get-OptionalProp $signals 'Manufacturer' }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
    if (-not [string]::IsNullOrWhiteSpace([string]$DefaultManufacturer)) { return [string]$DefaultManufacturer }
    return $null
}

function ConvertTo-DeviceActionResult {
    <# Maps a command outcome to a ProviderResult using the .NET provider semantics. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Outcome, [Parameter(Mandatory)][string] $SuccessDetail, [Parameter(Mandatory)][string] $TimeoutDetail, [Parameter(Mandatory)][string] $FailDetailPrefix)
    if ($Outcome.TimedOut) { return New-ProviderResult -Status 'Failed' -Detail $TimeoutDetail -Transient }
    if ($Outcome.Success) { return New-ProviderResult -Status 'Success' -Detail "$SuccessDetail (exit $($Outcome.ExitCode))" }
    $trimmed = [string]$Outcome.Output
    if ($trimmed.Length -gt 500) { $trimmed = $trimmed.Substring(0, 500) }
    return New-ProviderResult -Status 'Failed' -Detail "$FailDetailPrefix (exit $($Outcome.ExitCode)): $trimmed"
}

function Get-DeviceActionTimeoutSeconds {
    param($Options)
    $t = Get-OptionalProp $Options 'CommandTimeoutSeconds'
    if ($null -ne $t -and [int]$t -gt 0) { return [int]$t }
    return 300
}

function Invoke-LicenseRemoval {
    <# Removes the Enterprise license (step-down to Pro). Parity with LicenseRemovalProvider.DeleteAsync. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] $Options, [switch] $DryRun, [hashtable] $LogProperties = @{})
    $spec = Get-OptionalProp $Options 'LicenseRemoval'
    if (-not (Test-CommandSpecConfigured -Spec $spec)) {
        return New-ProviderResult -Status 'Skipped' -Detail 'license removal command not configured'
    }
    if ($DryRun -or [bool](Get-OptionalProp $Options 'DryRun')) {
        return New-ProviderResult -Status 'Success' -Detail "[DRY-RUN] would remove Enterprise license via '$(Get-OptionalProp $spec 'FileName')'"
    }
    try {
        $outcome = Invoke-LocalCommand -Spec $spec -Context $Context -TimeoutSeconds (Get-DeviceActionTimeoutSeconds -Options $Options)
        return ConvertTo-DeviceActionResult -Outcome $outcome -SuccessDetail 'Enterprise license removed' `
            -TimeoutDetail 'license removal timed out' -FailDetailPrefix 'license removal failed'
    }
    catch {
        Write-AtLog -Level 'Warning' -Message "License removal failed: $($_.Exception.Message)" -Properties $LogProperties
        return New-ProviderResult -Status 'Failed' -Detail $_.Exception.Message -Transient
    }
}

function Invoke-BiosPasswordRemoval {
    <# Clears the BIOS/UEFI supervisor password via the OEM tool. Parity with BiosPasswordRemovalProvider.DeleteAsync. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] $Options, [switch] $DryRun, [hashtable] $LogProperties = @{})
    $manufacturer = Resolve-DeviceManufacturer -Context $Context -DefaultManufacturer ([string](Get-OptionalProp $Options 'DefaultManufacturer'))
    if ([string]::IsNullOrWhiteSpace($manufacturer)) {
        return New-ProviderResult -Status 'Skipped' -Detail 'device manufacturer unknown; no BIOS tool selected'
    }
    $map = Get-OptionalProp $Options 'BiosPasswordRemoval'
    $spec = $null
    if ($null -ne $map) {
        if ($map -is [System.Collections.IDictionary]) {
            foreach ($k in $map.Keys) { if ([string]$k -ieq $manufacturer) { $spec = $map[$k]; break } }
        }
        else { $spec = Get-OptionalProp $map $manufacturer }
    }
    if (-not (Test-CommandSpecConfigured -Spec $spec)) {
        return New-ProviderResult -Status 'Skipped' -Detail "no BIOS password removal tool configured for '$manufacturer'"
    }
    if ($DryRun -or [bool](Get-OptionalProp $Options 'DryRun')) {
        return New-ProviderResult -Status 'Success' -Detail "[DRY-RUN] would clear BIOS password via '$(Get-OptionalProp $spec 'FileName')' ($manufacturer)"
    }
    try {
        $outcome = Invoke-LocalCommand -Spec $spec -Context $Context -TimeoutSeconds (Get-DeviceActionTimeoutSeconds -Options $Options)
        return ConvertTo-DeviceActionResult -Outcome $outcome -SuccessDetail "BIOS password cleared via $manufacturer tool" `
            -TimeoutDetail "BIOS password removal timed out ($manufacturer)" -FailDetailPrefix 'BIOS password removal failed'
    }
    catch {
        Write-AtLog -Level 'Warning' -Message "BIOS password removal failed: $($_.Exception.Message)" -Properties $LogProperties
        return New-ProviderResult -Status 'Failed' -Detail $_.Exception.Message -Transient
    }
}

function Get-DeviceActionPendingStatus {
    <# On-device one-shot actions expose no live status; poller waits. Parity with GetStatusAsync. #>
    [CmdletBinding()]
    param()
    return New-ProviderResult -Status 'Failed' -Detail 'pending on-prem agent execution' -Transient
}

Export-ModuleMember -Function Expand-CommandTemplate, Test-CommandSpecConfigured, Invoke-LocalCommand, `
    Resolve-DeviceManufacturer, ConvertTo-DeviceActionResult, Get-DeviceActionTimeoutSeconds, `
    Invoke-LicenseRemoval, Invoke-BiosPasswordRemoval, Get-DeviceActionPendingStatus
