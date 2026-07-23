using namespace System.Net

# DecommissionHistory — HTTP GET v1/decommission/{requestId}/history
# Parity with AssetTerminator.Api DecommissionQueryFunction.GetHistory.
# Returns the immutable, hash-chained event timeline for a request.

param($Request, $TriggerMetadata)

$ingestion = Get-IngestionOptions
$deny = Test-HttpAuthGate -Request $Request -Config $ingestion
if ($deny) { Write-HttpJson -StatusCode $deny.StatusCode -Body @{ status = $deny.StatusCode; detail = $deny.Detail }; return }

$requestId = [string]$Request.Params.requestId
if ([string]::IsNullOrWhiteSpace($requestId)) { Write-HttpJson -StatusCode 400 -Body @{ status = 400; detail = 'requestId is required.' }; return }

try {
    $record = Get-DecommissionRequest -RequestId $requestId
}
catch {
    Write-AtLog -Level 'Error' -Message "History lookup failed: $($_.Exception.Message)" -Properties @{ requestId = $requestId }
    Write-HttpJson -StatusCode 500 -Body @{ status = 500; detail = 'Failed to read request state.' }
    return
}

if (-not $record) { Write-HttpJson -StatusCode 404 -Body @{ status = 404; detail = "Request '$requestId' not found." }; return }

$timeline = @(Get-AuditTimeline -RequestId $requestId | ForEach-Object { ConvertTo-HistoryEvent -Audit $_ })
Write-HttpJson -StatusCode 200 -Body $timeline
