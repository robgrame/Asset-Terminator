# Observability.psm1  (nested in AT.Infrastructure)
# Operational telemetry to Log Analytics custom tables via the Logs Ingestion API
# (Data Collection Rule/Endpoint) with a Managed Identity token. Parity with
# AssetTerminator.Infrastructure.Observability.LogsIngestionTelemetry.
#
# When the DCR endpoint/immutable id are not configured the emitter is a no-op
# (telemetry still flows to Application Insights via Write-AtLog).
#
# Configuration (app settings):
#   DCR_ENDPOINT      : https://<name>.<region>.ingest.monitor.azure.com
#   DCR_IMMUTABLE_ID  : dcr-xxxx…
#   DCR_REQUESTS_STREAM  (default 'Custom-DecommissionRequests_CL')
#   DCR_ACTIONS_STREAM   (default 'Custom-DecommissionActions_CL')
#   DCR_GUARDRAILS_STREAM(default 'Custom-GuardrailResults_CL')
#   DCR_CALLBACKS_STREAM (default 'Custom-CallbackEvents_CL')

Set-StrictMode -Version Latest

$script:MonitorResource = 'https://monitor.azure.com'
$script:IngestApiVersion = '2023-01-01'

function Send-Telemetry {
    <#
        .SYNOPSIS
            Emits one or more rows to a Log Analytics custom stream. No-op when the
            DCR is not configured.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Stream,
        [Parameter(Mandatory)] $Rows
    )
    if (-not $env:DCR_ENDPOINT -or -not $env:DCR_IMMUTABLE_ID) {
        Write-AtLog -Message "Telemetry (DCR not configured, no-op): $Stream"
        return
    }
    $uri = "$($env:DCR_ENDPOINT.TrimEnd('/'))/dataCollectionRules/$($env:DCR_IMMUTABLE_ID)/streams/$Stream`?api-version=$script:IngestApiVersion"
    $payload = @($Rows)
    Invoke-AtRetry -ScriptBlock {
        $token = Get-IdentityToken -Resource $script:MonitorResource
        $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
        Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body ($payload | ConvertTo-Json -Depth 10 -AsArray) -ErrorAction Stop
    } | Out-Null
}

function Send-RequestSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Record)
    $stream = $env:DCR_REQUESTS_STREAM ? $env:DCR_REQUESTS_STREAM : 'Custom-DecommissionRequests_CL'
    Send-Telemetry -Stream $stream -Rows ([pscustomobject]@{
        TimeGenerated  = ([datetime]::UtcNow).ToString('o')
        RequestId      = $Record.requestId
        CorrelationId  = $Record.correlationId
        State          = $Record.state
        AssetCategory  = $Record.assetCategory
        DispositionType= $Record.dispositionType
        DryRun         = [bool]$Record.dryRun
    })
}

Export-ModuleMember -Function Send-Telemetry, Send-RequestSnapshot
