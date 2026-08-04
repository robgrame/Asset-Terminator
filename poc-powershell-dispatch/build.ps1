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
    Module-only directives are removed and the PowerShell functions are written
    directly into run.ps1 so a reviewer can read and search the complete code
    without decoding strings or following imports.

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

function Get-InlinedModuleBlock {
    param([Parameter(Mandatory)] [string[]] $ModuleNames)

    $seenFunctions = @{}
    $seenScriptVariables = @{}
    $blocks = foreach ($moduleName in $ModuleNames) {
        $modulePath = Join-Path $moduleRoot "$moduleName.psm1"
        if (-not (Test-Path $modulePath)) { throw "Shared module not found: $modulePath" }

        $moduleSource = Get-Content $modulePath -Raw
        $cleanLines = [System.Collections.Generic.List[string]]::new()
        $skippingExport = $false

        foreach ($line in [regex]::Split($moduleSource, '\r?\n')) {
            if ($skippingExport) {
                $skippingExport = $line.TrimEnd().EndsWith('`')
                continue
            }
            if ($line -match '^[ \t]*#Requires[ \t]+-Version\b') { continue }
            if ($line -match '^[ \t]*Import-Module[^\r\n]*AT\.[A-Za-z]+\.psm1') { continue }
            if ($line -match '^[ \t]*Export-ModuleMember\b') {
                $skippingExport = $line.TrimEnd().EndsWith('`')
                continue
            }
            $cleanLines.Add($line)
        }

        $moduleSource = ($cleanLines -join [Environment]::NewLine).Trim()
        $moduleFunctions = [regex]::Matches(
            $moduleSource,
            '(?m)^[ \t]*function[ \t]+([A-Za-z0-9_-]+)[ \t]*\{'
        ) | ForEach-Object { $_.Groups[1].Value }

        foreach ($functionName in $moduleFunctions) {
            if ($seenFunctions.ContainsKey($functionName)) {
                throw "Function '$functionName' is defined by both $($seenFunctions[$functionName]) and $moduleName."
            }
            $seenFunctions[$functionName] = $moduleName
        }

        $scriptVariables = [regex]::Matches(
            $moduleSource,
            '\$script:([A-Za-z_][A-Za-z0-9_]*)'
        ) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

        foreach ($variableName in $scriptVariables) {
            if ($seenScriptVariables.ContainsKey($variableName)) {
                throw "Script variable '$variableName' is used by both $($seenScriptVariables[$variableName]) and $moduleName."
            }
            $seenScriptVariables[$variableName] = $moduleName
        }

        @"
# region Inlined functions from: $moduleName.psm1
$moduleSource
# endregion Inlined functions from: $moduleName.psm1
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

    $inlinedModules = Get-InlinedModuleBlock -ModuleNames $entry.Value
    $generatedHeader = @"
# -----------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT DIRECTLY.
# Source handler: handler.ps1
# Shared sources: ../../shared/Modules/*.psm1
# Regenerate with: ./build.ps1 -Clean
# -----------------------------------------------------------------------------

$inlinedModules
"@

    $runSource = [regex]::Replace($handlerSource, $importPattern, '')
    $paramStart = $runSource.IndexOf('param(')
    $paramEnd = if ($paramStart -ge 0) { $runSource.IndexOf(')', $paramStart) } else { -1 }
    if ($paramEnd -lt 0) { throw "Unable to locate the param block in $handlerPath" }
    $runSource = $runSource.Insert($paramEnd + 1, "`r`n`r`n$generatedHeader")

    [System.IO.File]::WriteAllText($runPath, $runSource, [System.Text.UTF8Encoding]::new($false))

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($runPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Generated script is invalid ($runPath): $($parseErrors -join '; ')"
    }

    $generatedSource = Get-Content $runPath -Raw
    if ($generatedSource -match $importPattern) {
        throw "Generated script still contains an external AT module import: $runPath"
    }
    if ($generatedSource -match '(?m)^[ \t]*(?:Export-ModuleMember|New-Module)\b' -or
        $generatedSource -match '\$embeddedSource\b') {
        throw "Generated script still contains dynamic-module infrastructure: $runPath"
    }

    $duplicateFunctions = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true
    ) | Group-Object Name | Where-Object Count -gt 1
    if ($duplicateFunctions) {
        throw "Generated script contains duplicate functions ($runPath): $(($duplicateFunctions.Name) -join ', ')"
    }

    foreach ($moduleName in $entry.Value) {
        $regionPattern = "(?m)^# region Inlined functions from: $([regex]::Escape($moduleName))\.psm1\r?$"
        if ([regex]::Matches($generatedSource, $regionPattern).Count -ne 1) {
            throw "Generated script must inline $moduleName.psm1 exactly once: $runPath"
        }
    }

    $functionCount = @($ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true
    )).Count
    Write-Host "==> $($entry.Key)/run.ps1 generated with $functionCount directly readable function(s)" -ForegroundColor Green
}
