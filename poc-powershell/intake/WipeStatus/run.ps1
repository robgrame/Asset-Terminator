using namespace System.Net

# WipeStatus - HTTP trigger (Intake Function App)
# Returns the current decommission state and event history for a requestId,
# read from the Table Storage state store. Enables ServiceNow polling:
#   GET /api/v1/decommission/{requestId}

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/Common.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/StateStore.psm1" -Force

$requestId = $Request.Params.requestId

function Write-Json {
    param([int] $StatusCode, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = ($Object | ConvertTo-Json -Depth 8)
    })
}

if (-not $requestId) {
    Write-Json -StatusCode 400 -Object @{ error = 'requestId is required in the route.' }
    return
}

try {
    $state = Get-DecommissionState -RequestId $requestId
    if (-not $state) {
        Write-Json -StatusCode 404 -Object @{ error = "No decommission request found for requestId '$requestId'." }
        return
    }

    $history = @(Get-DecommissionHistory -RequestId $requestId | ForEach-Object {
        @{
            status    = $_.OverallStatus
            timestamp = $_.Timestamp_
            detail    = $_.Detail
        }
    })

    Write-Json -StatusCode 200 -Object @{
        requestId     = $state.RequestId
        correlationId = $state.CorrelationId
        overallStatus = $state.OverallStatus
        deviceName    = $state.DeviceName
        serialNumber  = $state.SerialNumber
        ticketNumber  = $state.TicketNumber
        dryRun        = $state.DryRun
        createdAt     = $state.CreatedAt
        lastUpdatedAt = $state.LastUpdatedAt
        detail        = $state.Detail
        history       = $history
    }
}
catch {
    Write-PocLog -Level 'Error' -Message "Failed to read state: $($_.Exception.Message)" -Properties @{ requestId = $requestId }
    Write-Json -StatusCode 500 -Object @{ error = 'Failed to read state.' }
}
