<#
.SYNOPSIS
    Copies the shared PowerShell modules into each Function App before publish.

.DESCRIPTION
    The api and worker Function Apps are deployed separately (different managed
    identities, different permissions) but share the same helper modules. Azure
    Functions requires modules to live inside the app root, so they are copied
    here rather than referenced across folders.

    Run this before `func azure functionapp publish`, or use infra/deploy.ps1
    which calls it automatically.
#>
[CmdletBinding()]
param(
    [switch] $Clean
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$source = Join-Path $root 'shared/Modules'

foreach ($app in @('api', 'worker')) {
    $target = Join-Path $root "$app/Modules"

    if ($Clean -and (Test-Path $target)) {
        Remove-Item $target -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item (Join-Path $source '*.psm1') $target -Force

    Write-Host "==> $app/Modules synchronised" -ForegroundColor Green
}
