# Shared helpers for the Asset-Terminator dispatch PoC:
# app settings, structured logging, managed-identity tokens, platform mapping
# and a minimal JSON path resolver used by the runbook parameter binding.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TokenCache = @{}

function Get-AppSetting {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $Default = $null,
        [switch] $Required
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Required) { throw "Application setting '$Name' is not configured." }
        return $Default
    }
    return $value
}

function Get-AppSettingBool {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [bool] $Default = $false
    )

    $value = Get-AppSetting -Name $Name
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }

    $parsed = $false
    if ([bool]::TryParse($value, [ref] $parsed)) { return $parsed }
    return $Default
}

function Get-AppSettingInt {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [int] $Default = 0
    )

    $value = Get-AppSetting -Name $Name
    $parsed = 0
    if ([int]::TryParse($value, [ref] $parsed)) { return $parsed }
    return $Default
}

function Write-AtLog {
    param(
        [ValidateSet('Information', 'Warning', 'Error')] [string] $Level = 'Information',
        [Parameter(Mandatory)] [string] $Message,
        [hashtable] $Properties
    )

    $entry = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        level     = $Level
        message   = $Message
    }

    if ($Properties) {
        foreach ($key in $Properties.Keys) {
            if ($null -ne $Properties[$key] -and "$($Properties[$key])" -ne '') {
                $entry[$key] = $Properties[$key]
            }
        }
    }

    $line = ($entry | ConvertTo-Json -Depth 6 -Compress)

    switch ($Level) {
        'Error'   { Write-Error $line -ErrorAction Continue }
        'Warning' { Write-Warning $line }
        default   { Write-Information $line -InformationAction Continue }
    }
}

# ---------------------------------------------------------------------------
# Managed identity tokens (Functions IDENTITY_ENDPOINT protocol)
# ---------------------------------------------------------------------------
function Get-ManagedIdentityToken {
    param(
        [Parameter(Mandatory)] [string] $Resource,
        [switch] $Force
    )

    $cached = $script:TokenCache[$Resource]
    if (-not $Force -and $cached -and $cached.ExpiresOn -gt (Get-Date).AddMinutes(5)) {
        return $cached.Token
    }

    $identityEndpoint = Get-AppSetting -Name 'IDENTITY_ENDPOINT'
    $identityHeader = Get-AppSetting -Name 'IDENTITY_HEADER'
    if ([string]::IsNullOrWhiteSpace($identityEndpoint)) {
        throw 'IDENTITY_ENDPOINT is not available: the app has no managed identity assigned.'
    }

    $uri = "$identityEndpoint" + "?resource=$([uri]::EscapeDataString($Resource))&api-version=2019-08-01"

    $clientId = Get-AppSetting -Name 'UAMI_CLIENT_ID'
    if (-not [string]::IsNullOrWhiteSpace($clientId)) {
        $uri += "&client_id=$([uri]::EscapeDataString($clientId))"
    }

    $response = Invoke-RestMethod -Uri $uri -Method GET -Headers @{ 'X-IDENTITY-HEADER' = $identityHeader }

    $expiresOn = (Get-Date).AddMinutes(50)
    if ($response.PSObject.Properties.Name -contains 'expires_on') {
        $epoch = 0L
        if ([long]::TryParse("$($response.expires_on)", [ref] $epoch)) {
            $expiresOn = [DateTimeOffset]::FromUnixTimeSeconds($epoch).LocalDateTime
        }
    }

    $script:TokenCache[$Resource] = @{ Token = $response.access_token; ExpiresOn = $expiresOn }
    return $response.access_token
}

# ---------------------------------------------------------------------------
# Platform mapping
# ---------------------------------------------------------------------------

# ServiceNow speaks in operating systems (Windows / Mac / Mobile); the pipeline
# routes on the *enrollment platform* (Windows -> Autopilot, Apple -> ABM,
# Android -> Samsung KME / Zero-Touch).
function ConvertTo-EnrollmentPlatform {
    param([string] $OperatingSystem)

    if ([string]::IsNullOrWhiteSpace($OperatingSystem)) { return $null }

    switch ($OperatingSystem.Trim().ToLowerInvariant()) {
        { $_ -in @('windows', 'win', 'windows10', 'windows11') } { return 'Windows' }
        { $_ -in @('mac', 'macos', 'osx', 'ios', 'ipados', 'apple') } { return 'Apple' }
        { $_ -in @('android', 'androidenterprise') } { return 'Android' }
        # 'Mobile' is ambiguous: the intake resolves it against Intune before publishing.
        { $_ -in @('mobile') } { return 'Mobile' }
        default { return $null }
    }
}

function ConvertTo-ValidScenario {
    param([string] $Scenario)

    if ([string]::IsNullOrWhiteSpace($Scenario)) { return 'Disposal' }

    switch ($Scenario.Trim().ToLowerInvariant()) {
        { $_ -in @('retirement', 'ritiro', 'retire') } { return 'Retirement' }
        { $_ -in @('sale', 'vendita') } { return 'Sale' }
        { $_ -in @('disposal', 'smaltimento', 'dismissione') } { return 'Disposal' }
        { $_ -in @('loststolen', 'lost', 'stolen', 'furto', 'smarrimento') } { return 'LostStolen' }
        default { return $null }
    }
}

# Only Sale and Disposal remove the device from its enrollment platform;
# Retirement keeps it enrolled so the asset can be reused.
function Test-RemoveFromEnrollmentPlatform {
    param([Parameter(Mandatory)] [string] $Scenario)
    return $Scenario -in @('Sale', 'Disposal')
}

# ---------------------------------------------------------------------------
# Minimal '$.a.b' resolver used by RUNBOOK_MAP parameter binding
# ---------------------------------------------------------------------------
function Resolve-JsonPath {
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not $Path.StartsWith('$.')) { return $Path }

    $current = $InputObject
    foreach ($segment in $Path.Substring(2).Split('.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $null }
            $current = $current[$segment]
        }
        else {
            $property = $current.PSObject.Properties[$segment]
            if ($null -eq $property) { return $null }
            $current = $property.Value
        }
    }
    return $current
}

function ConvertFrom-JsonBody {
    param($Body)

    if ($null -eq $Body) { return $null }
    if ($Body -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
        try { return $Body | ConvertFrom-Json } catch { return $null }
    }
    if ($Body -is [byte[]]) {
        try { return [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json } catch { return $null }
    }
    return $Body
}

Export-ModuleMember -Function Get-AppSetting, Get-AppSettingBool, Get-AppSettingInt, Write-AtLog, `
    Get-ManagedIdentityToken, ConvertTo-EnrollmentPlatform, ConvertTo-ValidScenario, `
    Test-RemoveFromEnrollmentPlatform, Resolve-JsonPath, ConvertFrom-JsonBody
