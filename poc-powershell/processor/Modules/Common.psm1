# Common.psm1
# Shared helpers for the Asset-Terminator PowerShell POC:
# structured logging, Managed Identity Graph token acquisition, and a resilient
# Graph REST wrapper with retry/backoff.

$script:GraphBaseUri = 'https://graph.microsoft.com/beta'

function Write-PocLog {
    <#
        .SYNOPSIS
            Emits a single-line structured log entry that flows to Application Insights.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('Information', 'Warning', 'Error')][string] $Level = 'Information',
        [hashtable] $Properties
    )

    $payload = [ordered]@{
        timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        level         = $Level
        message       = $Message
        correlationId = $Properties.correlationId
    }
    if ($Properties) {
        foreach ($key in $Properties.Keys) { $payload[$key] = $Properties[$key] }
    }

    $line = ($payload | ConvertTo-Json -Compress -Depth 6)
    switch ($Level) {
        'Error'   { Write-Error   $line }
        'Warning' { Write-Warning $line }
        default   { Write-Information $line -InformationAction Continue }
    }
}

function New-CorrelationId {
    [CmdletBinding()]
    param()
    return [guid]::NewGuid().ToString()
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
        .PARAMETER Resource
            The audience, e.g. https://graph.microsoft.com or https://storage.azure.com.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Resource,
        [string] $ClientId = $env:UAMI_CLIENT_ID
    )

    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $uri = "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01"
        if ($ClientId) { $uri += "&client_id=$ClientId" }
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }
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
    <#
        .SYNOPSIS
            Returns a Microsoft Graph access token (delegates to Get-IdentityToken).
    #>
    [CmdletBinding()]
    param(
        [string] $Resource = 'https://graph.microsoft.com'
    )
    return Get-IdentityToken -Resource $Resource
}

function Invoke-GraphRequest {
    <#
        .SYNOPSIS
            Resilient Microsoft Graph REST call with retry/backoff on transient errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [object] $Body,
        [int] $MaxRetries = 4
    )

    $token = Get-GraphToken
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $uri = if ($Path -match '^https?://') { $Path } else { "$script:GraphBaseUri/$($Path.TrimStart('/'))" }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $params = @{ Method = $Method; Uri = $uri; Headers = $headers; ErrorAction = 'Stop' }
            if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
                $params.Body = ($Body | ConvertTo-Json -Depth 8)
            }
            return Invoke-RestMethod @params
        }
        catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }

            $isTransient = $status -in @(429, 500, 502, 503, 504)
            if (-not $isTransient -or $attempt -gt $MaxRetries) {
                throw
            }

            $delay = [math]::Min([math]::Pow(2, $attempt), 30)
            Write-PocLog -Level 'Warning' -Message "Graph $Method $uri failed (status $status), retry $attempt/$MaxRetries in ${delay}s"
            Start-Sleep -Seconds $delay
        }
    }
}

Export-ModuleMember -Function Write-PocLog, New-CorrelationId, Get-IdentityToken, Get-GraphToken, Invoke-GraphRequest
