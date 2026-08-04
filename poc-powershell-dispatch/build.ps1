#Requires -Version 7.6

<#
.SYNOPSIS
    Generates self-contained run.ps1 files for every Function.

.DESCRIPTION
    The api and worker Function Apps are deployed separately (different managed
    identities, different permissions) but share helper modules. For customer
    auditability, each generated run.ps1 contains the complete source of every
    module used by that Function, followed by its handler code.

    The maintainable sources remain handler.ps1 and shared/Modules/*.psm1.
    Embedded modules are loaded as dynamic modules so their script-scoped state
    remains isolated exactly as it is when loading separate .psm1 files.

    Run this before `func azure functionapp publish`, or use infra/deploy.ps1
    which calls it automatically.
#>
[CmdletBinding()]
param(
    [switch] $Clean
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$moduleRoot = Join-Path $root 'shared/Modules'

$functions = [ordered]@{
    'api/WipeIntake'         = @('AT.Common', 'AT.Graph', 'AT.State', 'AT.Messaging')
    'api/GetStatus'          = @('AT.Common', 'AT.State')
    'worker/DispatchWindows' = @('AT.Common', 'AT.State', 'AT.Automation', 'AT.Dispatch')
    'worker/DispatchApple'   = @('AT.Common', 'AT.State', 'AT.Automation', 'AT.Dispatch')
    'worker/DispatchAndroid' = @('AT.Common', 'AT.State', 'AT.Automation', 'AT.Dispatch')
    'worker/JobMonitor'      = @('AT.Common', 'AT.State', 'AT.Automation')
}

function Get-EmbeddedModuleBlock {
    param([Parameter(Mandatory)] [string[]] $ModuleNames)

    $blocks = foreach ($moduleName in $ModuleNames) {
        $modulePath = Join-Path $moduleRoot "$moduleName.psm1"
        if (-not (Test-Path $modulePath)) { throw "Shared module not found: $modulePath" }

        $moduleSource = Get-Content $modulePath -Raw
        # Dependencies are already embedded and imported by the generated file.
        $moduleSource = $moduleSource -replace '(?m)^[ \t]*Import-Module[^\r\n]*AT\.[A-Za-z]+\.psm1[^\r\n]*\r?\n?', ''

        @"
# region Embedded module: $moduleName.psm1
`$embeddedSource = @'
$($moduleSource.TrimEnd())
'@
`$embeddedModule = New-Module -Name 'Embedded.$moduleName' -ScriptBlock ([scriptblock]::Create(`$embeddedSource))
Import-Module `$embeddedModule -Global -Force
Remove-Variable embeddedSource, embeddedModule -ErrorAction SilentlyContinue
# endregion Embedded module: $moduleName.psm1
"@
    }

    return ($blocks -join [Environment]::NewLine)
}

if ($Clean) {
    foreach ($legacyModules in @('api/Modules', 'worker/Modules')) {
        $legacyPath = Join-Path $root $legacyModules
        if (Test-Path $legacyPath) { Remove-Item $legacyPath -Recurse -Force }
    }
}

foreach ($entry in $functions.GetEnumerator()) {
    $functionDir = Join-Path $root $entry.Key
    $handlerPath = Join-Path $functionDir 'handler.ps1'
    $runPath = Join-Path $functionDir 'run.ps1'
    if (-not (Test-Path $handlerPath)) { throw "Function handler not found: $handlerPath" }

    $handlerSource = Get-Content $handlerPath -Raw
    $importPattern = '(?m)^[ \t]*Import-Module[^\r\n]*AT\.[A-Za-z]+\.psm1[^\r\n]*\r?\n?'
    if ($handlerSource -notmatch $importPattern) {
        throw "Function handler does not contain an AT module import: $handlerPath"
    }

    $embeddedModules = Get-EmbeddedModuleBlock -ModuleNames $entry.Value
    $generatedHeader = @"
# -----------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT DIRECTLY.
# Source handler: handler.ps1
# Shared sources: ../../shared/Modules/*.psm1
# Regenerate with: ./build.ps1 -Clean
# -----------------------------------------------------------------------------

$embeddedModules
"@

    $runSource = [regex]::Replace($handlerSource, $importPattern, '')
    $paramStart = $runSource.IndexOf('param(')
    $paramEnd = if ($paramStart -ge 0) { $runSource.IndexOf(')', $paramStart) } else { -1 }
    if ($paramEnd -lt 0) { throw "Unable to locate the param block in $handlerPath" }
    $runSource = $runSource.Insert($paramEnd + 1, "`r`n`r`n$generatedHeader")

    [System.IO.File]::WriteAllText($runPath, $runSource, [System.Text.UTF8Encoding]::new($false))

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($runPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        throw "Generated script is invalid ($runPath): $($parseErrors -join '; ')"
    }

    $generatedSource = Get-Content $runPath -Raw
    if ($generatedSource -match $importPattern) {
        throw "Generated script still contains an external AT module import: $runPath"
    }

    foreach ($moduleName in $entry.Value) {
        $regionPattern = "(?m)^# region Embedded module: $([regex]::Escape($moduleName))\.psm1\r?$"
        if ([regex]::Matches($generatedSource, $regionPattern).Count -ne 1) {
            throw "Generated script must embed $moduleName.psm1 exactly once: $runPath"
        }
    }

    Write-Host "==> $($entry.Key)/run.ps1 generated with $($entry.Value.Count) embedded module(s)" -ForegroundColor Green
}
