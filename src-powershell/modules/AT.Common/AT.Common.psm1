# AT.Common.psm1
# Foundation module for the parallel PowerShell implementation of Asset-Terminator.
# Provides cross-cutting primitives shared by every app and module:
#   * structured single-line logging (flows to Application Insights / Log Analytics)
#   * correlation ids
#   * Entra access-token acquisition via Managed Identity (with Azure CLI fallback)
#   * a resilient Microsoft Graph REST wrapper with retry/backoff
#   * a generic transient-retry helper
#
# This mirrors the cross-cutting concerns of AssetTerminator.Infrastructure
# (GraphClientFactory, Resilience) and AssetTerminator.Core logging, without any
# .NET dependency.

Set-StrictMode -Version Latest

$script:GraphBaseUri     = 'https://graph.microsoft.com/beta'
$script:TransientStatus  = @(408, 429, 500, 502, 503, 504)

function Write-AtLog {
    <#
        .SYNOPSIS
            Emits a single-line JSON structured log entry.
        .DESCRIPTION
            Structured logging is the parity replacement for the .NET ILogger
            structured events. Each entry carries a UTC timestamp, level, message
            and an optional correlationId plus arbitrary properties, so it can be
            queried in Application Insights / Log Analytics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('Information', 'Warning', 'Error')][string] $Level = 'Information',
        [hashtable] $Properties
    )

    $payload = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        level     = $Level
        message   = $Message
    }
    if ($Properties) {
        foreach ($key in $Properties.Keys) { $payload[$key] = $Properties[$key] }
    }

    $line = ($payload | ConvertTo-Json -Compress -Depth 8)
    switch ($Level) {
        'Error'   { Write-Error   $line -ErrorAction Continue }
        'Warning' { Write-Warning $line }
        default   { Write-Information $line -InformationAction Continue }
    }
}

function New-CorrelationId {
    [CmdletBinding()]
    param()
    return [guid]::NewGuid().ToString()
}

function Invoke-AtRetry {
    <#
        .SYNOPSIS
            Runs a script block with exponential backoff on transient failures.
        .DESCRIPTION
            Generic resilience primitive (parity with the .NET Resilience layer).
            The Predicate decides whether a caught error is transient; the default
            treats HTTP 408/429/5xx as transient.
        .PARAMETER ScriptBlock
            The operation to execute; its output is returned on success.
        .PARAMETER MaxRetries
            Maximum number of retries after the first attempt (default 4).
        .PARAMETER Predicate
            Optional { param($err) [bool] } deciding if an error is retryable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $ScriptBlock,
        [int] $MaxRetries = 4,
        [scriptblock] $Predicate,
        [double] $MaxDelaySeconds = 30
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            $retryable = if ($Predicate) { [bool](& $Predicate $_) } else { (Get-HttpStatus $_) -in $script:TransientStatus }
            if (-not $retryable -or $attempt -gt $MaxRetries) { throw }

            $delay = [math]::Min([math]::Pow(2, $attempt), $MaxDelaySeconds)
            Write-AtLog -Level 'Warning' -Message "Transient failure on attempt $attempt/$MaxRetries, retrying in ${delay}s" -Properties @{ error = $_.Exception.Message }
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-HttpStatus {
    <#
        .SYNOPSIS
            Best-effort extraction of an HTTP status code from a caught error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($null -ne $resp) { return [int]$resp.StatusCode }
    }
    catch { }
    return 0
}

function Get-IdentityToken {
    <#
        .SYNOPSIS
            Returns an Entra access token for the given resource/audience.
        .DESCRIPTION
            In Azure it uses the Functions Managed Identity endpoint
            (IDENTITY_ENDPOINT + IDENTITY_HEADER). Set UAMI_CLIENT_ID to target a
            specific user-assigned identity (required when several are assigned).
            Locally it falls back to the Azure CLI (az account get-access-token).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Resource,
        [string] $ClientId = $env:UAMI_CLIENT_ID
    )

    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $uri = "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01"
        if ($ClientId) { $uri += "&client_id=$ClientId" }
        $response = Invoke-AtRetry -ScriptBlock {
            Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER } -ErrorAction Stop
        }
        return $response.access_token
    }

    # Local development fallback.
    $token = az account get-access-token --resource $Resource --query accessToken -o tsv 2>$null
    if (-not $token) {
        throw "Unable to acquire a token for '$Resource': no Managed Identity endpoint and Azure CLI fallback failed."
    }
    return $token
}

function Get-GraphToken {
    [CmdletBinding()]
    param([string] $Resource = 'https://graph.microsoft.com', [string] $ClientId = $env:UAMI_CLIENT_ID)
    return Get-IdentityToken -Resource $Resource -ClientId $ClientId
}

function Invoke-GraphRequest {
    <#
        .SYNOPSIS
            Resilient Microsoft Graph REST call with retry/backoff on transient errors.
        .DESCRIPTION
            Parity replacement for the Microsoft Graph SDK usage in the .NET
            providers. Accepts a relative Graph path or an absolute URL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [object] $Body,
        [string] $ClientId = $env:UAMI_CLIENT_ID,
        [int] $MaxRetries = 4
    )

    $uri = if ($Path -match '^https?://') { $Path } else { "$script:GraphBaseUri/$($Path.TrimStart('/'))" }
    $hasBody = $PSBoundParameters.ContainsKey('Body') -and $null -ne $Body

    return Invoke-AtRetry -MaxRetries $MaxRetries -ScriptBlock {
        $token = Get-GraphToken -ClientId $ClientId
        $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
        $params = @{ Method = $Method; Uri = $uri; Headers = $headers; ErrorAction = 'Stop' }
        if ($hasBody) {
            $params.Body = if ($Body -is [string]) { $Body } else { ($Body | ConvertTo-Json -Depth 10) }
        }
        Invoke-RestMethod @params
    }
}

Export-ModuleMember -Function Write-AtLog, New-CorrelationId, Invoke-AtRetry, Get-HttpStatus, `
    Get-IdentityToken, Get-GraphToken, Invoke-GraphRequest
