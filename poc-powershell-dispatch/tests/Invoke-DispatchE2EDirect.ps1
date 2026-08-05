#Requires -Version 7.6

<#
.SYNOPSIS
    Runs the dispatch E2E test using only the Function endpoint and key.

.DESCRIPTION
    This entry point never queries Azure resources. It delegates to
    Invoke-DispatchE2E.ps1 in direct mode, preserving its intake validation,
    status polling, terminal evidence checks and live Intune wipe polling.

.EXAMPLE
    ./tests/Invoke-DispatchE2EDirect.ps1 `
        -Fqdn attdisp-func-api-dev.azurewebsites.net `
        -FunctionKey '<function-key>' `
        -SerialNumber 'SERIAL-1'

.EXAMPLE
    ./tests/Invoke-DispatchE2EDirect.ps1 `
        -Fqdn attdisp-func-api-dev.azurewebsites.net `
        -FunctionKey '<function-key>' `
        -SerialNumber 'SERIAL-1' `
        -Real
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Fqdn,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $FunctionKey,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SerialNumber,

    [ValidateSet('Windows', 'Apple', 'Android', 'Mobile')]
    [string] $OperatingSystem = 'Windows',

    [ValidateSet('Retirement', 'Sale', 'Disposal', 'LostStolen')]
    [string] $Scenario = 'Disposal',

    [ValidateRange(1, 86400)]
    [int] $TimeoutSeconds = 1800,

    [ValidateRange(1, 300)]
    [int] $PollIntervalSeconds = 10,

    [switch] $Real
)

$ErrorActionPreference = 'Stop'

$fqdnValue = $Fqdn.Trim().TrimEnd('/')
$baseUri = if ($fqdnValue -match '^https?://') {
    [uri]$fqdnValue
}
else {
    [uri]"https://$fqdnValue"
}

if (-not $baseUri.IsAbsoluteUri -or
    [string]::IsNullOrWhiteSpace($baseUri.Host) -or
    $baseUri.AbsolutePath -ne '/' -or
    -not [string]::IsNullOrWhiteSpace($baseUri.Query) -or
    -not [string]::IsNullOrWhiteSpace($baseUri.Fragment)) {
    throw "Fqdn must contain only a Function host name, optionally prefixed with https://."
}

if ($baseUri.Scheme -ne 'https') {
    throw 'Fqdn must use HTTPS.'
}

$parameters = @{
    BaseUri = $baseUri
    FunctionKey = $FunctionKey
    SerialNumber = $SerialNumber
    OperatingSystem = $OperatingSystem
    Scenario = $Scenario
    TimeoutSeconds = $TimeoutSeconds
    PollIntervalSeconds = $PollIntervalSeconds
}
if ($Real.IsPresent) { $parameters.Real = $true }

& (Join-Path $PSScriptRoot 'Invoke-DispatchE2E.ps1') @parameters
