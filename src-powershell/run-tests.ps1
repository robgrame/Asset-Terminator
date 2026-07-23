# run-tests.ps1
# Runs PSScriptAnalyzer over the parallel PowerShell source and the full Pester
# suite. Parity with `dotnet build` + `dotnet test` for the .NET solution.
[CmdletBinding()]
param(
    [switch] $SkipLint,
    [string] $Output = 'Detailed'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$modulesDir = Join-Path $root 'modules'

# Make the module tree importable by name.
if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $modulesDir) {
    $env:PSModulePath = $modulesDir + [IO.Path]::PathSeparator + $env:PSModulePath
}

$failed = $false

if (-not $SkipLint) {
    Write-Host '== PSScriptAnalyzer ==' -ForegroundColor Cyan
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    $diagnostics = Invoke-ScriptAnalyzer -Path $root -Recurse -Settings $settings
    if ($diagnostics) {
        $diagnostics | Format-Table -AutoSize | Out-String | Write-Host
        if ($diagnostics | Where-Object Severity -eq 'Error') { $failed = $true }
    }
    else {
        Write-Host 'No analyzer findings.' -ForegroundColor Green
    }
}

Write-Host '== Pester ==' -ForegroundColor Cyan
$cfg = New-PesterConfiguration
$cfg.Run.Path = (Join-Path $root 'tests')
$cfg.Output.Verbosity = $Output
$cfg.Run.PassThru = $true
$result = Invoke-Pester -Configuration $cfg

if ($result.FailedCount -gt 0) { $failed = $true }

if ($failed) { Write-Error 'Verification FAILED.'; exit 1 }
Write-Host 'Verification PASSED.' -ForegroundColor Green
