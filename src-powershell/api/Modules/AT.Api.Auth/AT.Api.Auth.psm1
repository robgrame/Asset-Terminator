# AT.Api.Auth.psm1
# HTTP authentication/authorization for the API Function App. Parity with
# AssetTerminator.Api.Auth (ApiKeyAuthMiddleware + CallerContext):
#   * shared API-key header (fail-closed) + source-IP allowlist (exact + CIDR)
#   * caller UPN + app-role extraction from the Easy Auth client principal,
#     with x-debug-upn / x-debug-roles dev fallback.

Set-StrictMode -Version Latest

$script:AppRoles = @{ Operator = 'Operator'; Auditor = 'Auditor'; Admin = 'Admin'; Approver = 'Approver' }
function Get-AppRoles { [CmdletBinding()] param() $script:AppRoles }

function Get-HeaderValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Headers, [Parameter(Mandatory)][string] $Name)
    if ($null -eq $Headers) { return $null }
    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            if ([string]::Equals([string]$key, $Name, [StringComparison]::OrdinalIgnoreCase)) {
                return [string]$Headers[$key]
            }
        }
        return $null
    }
    $prop = $Headers.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($prop) { return [string]$prop.Value }
    return $null
}

function Test-FixedTimeEqual {
    [CmdletBinding()]
    param([string] $A, [string] $B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    $ba = [Text.Encoding]::UTF8.GetBytes($A)
    $bb = [Text.Encoding]::UTF8.GetBytes($B)
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($ba, $bb)
}

function Test-CidrMatch {
    <# Returns $true when $Address falls within the CIDR range $Cidr. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Cidr, [Parameter(Mandatory)][ipaddress] $Address)
    $parts = $Cidr.Split('/')
    if ($parts.Length -ne 2) { return $false }
    [ipaddress]$network = $null
    if (-not [ipaddress]::TryParse($parts[0], [ref]$network)) { return $false }
    $prefix = 0
    if (-not [int]::TryParse($parts[1], [ref]$prefix)) { return $false }
    if ($network.AddressFamily -ne $Address.AddressFamily) { return $false }

    $nb = $network.GetAddressBytes()
    $ab = $Address.GetAddressBytes()
    if ($nb.Length -ne $ab.Length) { return $false }
    $fullBytes = [math]::Floor($prefix / 8)
    $remaining = $prefix % 8
    for ($i = 0; $i -lt $fullBytes; $i++) { if ($nb[$i] -ne $ab[$i]) { return $false } }
    if ($remaining -eq 0) { return $true }
    $mask = [byte]((0xFF -shl (8 - $remaining)) -band 0xFF)
    return ($nb[$fullBytes] -band $mask) -eq ($ab[$fullBytes] -band $mask)
}

function Test-IpAllowed {
    <# Empty allowlist = allow all. Otherwise match exact IP or CIDR. #>
    [CmdletBinding()]
    param([string] $RemoteIp, [string[]] $Allowlist)
    if ($null -eq $Allowlist -or $Allowlist.Count -eq 0) { return $true }
    if ([string]::IsNullOrWhiteSpace($RemoteIp)) { return $false }
    [ipaddress]$remote = $null
    if (-not [ipaddress]::TryParse($RemoteIp.Trim(), [ref]$remote)) { return $false }
    if ($remote.IsIPv4MappedToIPv6) { $remote = $remote.MapToIPv4() }
    foreach ($entry in $Allowlist) {
        $e = $entry.Trim()
        if ($e.Contains('/')) {
            if (Test-CidrMatch -Cidr $e -Address $remote) { return $true }
        }
        else {
            [ipaddress]$single = $null
            if ([ipaddress]::TryParse($e, [ref]$single) -and $single.Equals($remote)) { return $true }
        }
    }
    return $false
}

function Get-RemoteIp {
    <# Extracts the caller IP from X-Forwarded-For (first hop), stripping any port. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Headers)
    $xff = Get-HeaderValue -Headers $Headers -Name 'X-Forwarded-For'
    if ([string]::IsNullOrWhiteSpace($xff)) { return $null }
    $first = ($xff -split ',')[0].Trim()
    # X-Forwarded-For entries on Azure are ip:port — strip an IPv4 port suffix.
    if ($first -match '^(\d{1,3}(\.\d{1,3}){3}):\d+$') { return $Matches[1] }
    return $first
}

function Test-HttpAuthGate {
    <#
        .SYNOPSIS
            Enforces IP allowlist + API key. Returns $null when the request is
            authorized, otherwise a hashtable @{ StatusCode; Detail } to return.
        .PARAMETER Config
            Ingestion options object with: apiKeyHeader, apiKeys[], ipAllowlist[].
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Request, [Parameter(Mandatory)] $Config)

    $ipAllowlist = @(Get-OptionalProp $Config 'ipAllowlist')
    $remoteIp = Get-RemoteIp -Headers $Request.Headers
    if (-not (Test-IpAllowed -RemoteIp $remoteIp -Allowlist $ipAllowlist)) {
        return @{ StatusCode = 403; Detail = 'Source IP not allowed.' }
    }

    $apiKeys = @(Get-OptionalProp $Config 'apiKeys')
    if ($apiKeys.Count -eq 0) {
        return @{ StatusCode = 401; Detail = 'Missing or invalid API key.' } # fail-closed
    }
    $header = Get-OptionalProp $Config 'apiKeyHeader'
    if ([string]::IsNullOrWhiteSpace($header)) { $header = 'x-api-key' }
    $provided = Get-HeaderValue -Headers $Request.Headers -Name $header
    if ([string]::IsNullOrEmpty($provided)) {
        return @{ StatusCode = 401; Detail = 'Missing or invalid API key.' }
    }
    foreach ($k in $apiKeys) { if (Test-FixedTimeEqual -A $k -B $provided) { return $null } }
    return @{ StatusCode = 401; Detail = 'Missing or invalid API key.' }
}

function Get-CallerPrincipal {
    <# Decodes the Easy Auth x-ms-client-principal header (base64 JSON), or $null. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Headers)
    $raw = Get-HeaderValue -Headers $Headers -Name 'x-ms-client-principal'
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw))
        return $json | ConvertFrom-Json
    }
    catch { return $null }
}

function Get-CallerUpn {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Request)
    $principal = Get-CallerPrincipal -Headers $Request.Headers
    if ($principal) {
        $claims = @(Get-OptionalProp $principal 'claims')
        foreach ($type in @('upn', 'preferred_username', 'name', 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name')) {
            $match = $claims | Where-Object { (Get-OptionalProp $_ 'typ') -eq $type } | Select-Object -First 1
            if ($match) { $v = Get-OptionalProp $match 'val'; if ($v) { return [string]$v } }
        }
    }
    $debug = Get-HeaderValue -Headers $Request.Headers -Name 'x-debug-upn'
    if ($debug) { return $debug }
    return 'unknown'
}

function Get-CallerRoles {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Request)
    $roles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $principal = Get-CallerPrincipal -Headers $Request.Headers
    if ($principal) {
        $claims = @(Get-OptionalProp $principal 'claims')
        foreach ($c in $claims) {
            $typ = Get-OptionalProp $c 'typ'
            if ($typ -eq 'roles' -or $typ -eq 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role') {
                $val = Get-OptionalProp $c 'val'
                if ($val) { [void]$roles.Add([string]$val) }
            }
        }
    }
    if ($roles.Count -eq 0) {
        $debug = Get-HeaderValue -Headers $Request.Headers -Name 'x-debug-roles'
        if ($debug) {
            foreach ($r in ($debug -split ',')) { $t = $r.Trim(); if ($t) { [void]$roles.Add($t) } }
        }
    }
    return $roles
}

function Test-CallerInRole {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Request, [Parameter(Mandatory)][string] $Role)
    return (Get-CallerRoles -Request $Request).Contains($Role)
}

Export-ModuleMember -Function Get-AppRoles, Get-HeaderValue, Test-FixedTimeEqual, Test-CidrMatch, `
    Test-IpAllowed, Get-RemoteIp, Test-HttpAuthGate, Get-CallerPrincipal, Get-CallerUpn, `
    Get-CallerRoles, Test-CallerInRole
