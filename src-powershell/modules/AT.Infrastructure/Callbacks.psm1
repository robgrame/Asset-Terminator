# Callbacks.psm1  (nested in AT.Infrastructure)
# Pushes callbacks to ServiceNow over HTTP with exponential-backoff retry; on
# exhaustion the callback is dead-lettered to a Service Bus queue. Each callback
# carries a unique eventId for ServiceNow dedupe. Parity with
# AssetTerminator.Infrastructure.Callbacks.HttpServiceNowCallbackSender.
#
# Configuration (app settings):
#   CALLBACK_ENABLED     : 'true'/'false' (default true)
#   CALLBACK_URL         : ServiceNow callback endpoint
#   CALLBACK_AUTH_MODE   : 'oauth2' | 'apikey'
#   CALLBACK_APIKEY_HEADER / CALLBACK_APIKEY_SECRET (Key Vault secret name)
#   CALLBACK_TOKEN_ENDPOINT / CALLBACK_CLIENT_ID / CALLBACK_CLIENT_SECRET / CALLBACK_SCOPE
#   CALLBACK_MAX_RETRIES : default 5
#   CALLBACK_BASE_DELAY_SECONDS : default 2
#   SB_DLQ_QUEUE         : callback dead-letter queue (default 'callback-deadletter')

Set-StrictMode -Version Latest

function New-ServiceNowCallback {
    <#
        .SYNOPSIS
            Builds a callback payload with a unique eventId (idempotency key).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RequestId,
        [Parameter(Mandatory)][string] $OverallStatus,
        [string] $CorrelationId,
        [string] $Detail,
        $Actions
    )
    [pscustomobject][ordered]@{
        eventId       = [guid]::NewGuid().ToString()
        requestId     = $RequestId
        correlationId = $CorrelationId
        overallStatus = $OverallStatus
        detail        = $Detail
        actions       = $Actions
        timestampUtc  = ([datetime]::UtcNow).ToString('o')
    }
}

function Get-BackoffDelay {
    <#
        .SYNOPSIS
            Exponential backoff with optional jitter, capped. Pure/testable.
        .PARAMETER Attempt
            1-based attempt number.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $Attempt,
        [double] $BaseSeconds = 2,
        [double] $MaxSeconds = 300,
        [switch] $Jitter,
        [double] $JitterFactor
    )
    $delay = [math]::Min($BaseSeconds * [math]::Pow(2, $Attempt - 1), $MaxSeconds)
    if ($Jitter) {
        $f = $PSBoundParameters.ContainsKey('JitterFactor') ? $JitterFactor : (Get-Random -Minimum 0.0 -Maximum 1.0)
        $delay = $delay * (0.5 + 0.5 * $f)  # 50%..100% of the computed delay
    }
    return $delay
}

function Get-CallbackAuthHeader {
    <#
        .SYNOPSIS
            Resolves the auth header(s) for a callback based on CALLBACK_AUTH_MODE.
    #>
    [CmdletBinding()]
    param()
    $mode = ($env:CALLBACK_AUTH_MODE ? $env:CALLBACK_AUTH_MODE : 'oauth2').ToLowerInvariant()
    switch ($mode) {
        'apikey' {
            $header = $env:CALLBACK_APIKEY_HEADER
            $key = (Get-Command Resolve-Secret -ErrorAction SilentlyContinue) ? (Resolve-Secret -Name $env:CALLBACK_APIKEY_SECRET) : $null
            if ($header -and $key) { return @{ $header = $key } }
            return @{}
        }
        default {
            if (-not $env:CALLBACK_TOKEN_ENDPOINT -or -not $env:CALLBACK_CLIENT_ID) { return @{} }
            $secret = (Get-Command Resolve-Secret -ErrorAction SilentlyContinue) ? (Resolve-Secret -Name $env:CALLBACK_CLIENT_SECRET) : $null
            $form = @{ grant_type = 'client_credentials'; client_id = $env:CALLBACK_CLIENT_ID; client_secret = $secret }
            if ($env:CALLBACK_SCOPE) { $form['scope'] = $env:CALLBACK_SCOPE }
            $resp = Invoke-RestMethod -Method Post -Uri $env:CALLBACK_TOKEN_ENDPOINT -Body $form -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
            return @{ Authorization = "Bearer $($resp.access_token)" }
        }
    }
}

function Send-ServiceNowCallback {
    <#
        .SYNOPSIS
            Delivers a callback with retry; dead-letters on exhaustion. Parity with SendAsync.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Callback)

    $enabled = -not ($env:CALLBACK_ENABLED -and $env:CALLBACK_ENABLED -eq 'false')
    if (-not $enabled -or -not $env:CALLBACK_URL) {
        Write-AtLog -Message "Callback disabled or no URL; skipping $($Callback.eventId)"
        return
    }

    $maxRetries = $env:CALLBACK_MAX_RETRIES ? [int]$env:CALLBACK_MAX_RETRIES : 5
    $baseDelay  = $env:CALLBACK_BASE_DELAY_SECONDS ? [double]$env:CALLBACK_BASE_DELAY_SECONDS : 2

    for ($attempt = 1; $attempt -le ($maxRetries + 1); $attempt++) {
        try {
            $headers = @{ 'x-event-id' = $Callback.eventId; 'Content-Type' = 'application/json' }
            foreach ($kv in (Get-CallbackAuthHeader).GetEnumerator()) { $headers[$kv.Key] = $kv.Value }
            Invoke-RestMethod -Method Post -Uri $env:CALLBACK_URL -Headers $headers -Body ($Callback | ConvertTo-Json -Depth 8) -ErrorAction Stop | Out-Null
            Write-AtLog -Message "Callback $($Callback.eventId) delivered" -Properties @{ requestId = $Callback.requestId; overallStatus = $Callback.overallStatus }
            return
        }
        catch {
            if ($attempt -gt $maxRetries) {
                Write-AtLog -Level 'Error' -Message "Callback $($Callback.eventId) failed after retries; dead-lettering" -Properties @{ error = $_.Exception.Message }
                Send-CallbackToDeadLetter -Callback $Callback
                return
            }
            Start-Sleep -Seconds (Get-BackoffDelay -Attempt $attempt -BaseSeconds $baseDelay -Jitter)
        }
    }
}

function Send-CallbackToDeadLetter {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Callback)
    try {
        $queue = $env:SB_DLQ_QUEUE ? $env:SB_DLQ_QUEUE : 'callback-deadletter'
        if (Get-Command Send-ServiceBusMessage -ErrorAction SilentlyContinue) {
            Send-ServiceBusMessage -Queue $queue -Body $Callback -MessageId $Callback.eventId -Subject 'CallbackDeadLetter'
        }
    }
    catch {
        Write-AtLog -Level 'Error' -Message "Failed to dead-letter callback $($Callback.eventId)" -Properties @{ error = $_.Exception.Message }
    }
}

Export-ModuleMember -Function New-ServiceNowCallback, Get-BackoffDelay, Get-CallbackAuthHeader, `
    Send-ServiceNowCallback, Send-CallbackToDeadLetter
