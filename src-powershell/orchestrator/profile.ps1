# Azure Functions PowerShell profile — Orchestrator (Durable) Function App.
#
# Makes the shared AT.* modules discoverable. A deploy-time sync copies
# src-powershell/modules/* into this app's Modules/ folder (the source of truth
# stays under src-powershell/modules). During local development we also fall back
# to the repository modules directory so `func start` works without syncing.

$ErrorActionPreference = 'Stop'

$appModules = Join-Path $PSScriptRoot 'Modules'
$repoModules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($dir in @($appModules, $repoModules)) {
    if ((Test-Path $dir) -and (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $dir)) {
        $env:PSModulePath = $dir + [IO.Path]::PathSeparator + $env:PSModulePath
    }
}

Import-Module 'AT.Common' -Force
Import-Module 'AT.Contracts' -Force
Import-Module 'AT.Core' -Force
Import-Module 'AT.Infrastructure' -Force
Import-Module 'AT.Guardrails' -Force
Import-Module 'AT.Providers.Intune' -Force
Import-Module 'AT.Providers.EntraId' -Force
Import-Module 'AT.Orchestrator.Support' -Force
