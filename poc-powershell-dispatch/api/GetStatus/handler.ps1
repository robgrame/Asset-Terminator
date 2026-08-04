#Requires -Version 7.6

using namespace System.Net

# GetStatus handler - returns the durable state of a disposal request.
#
# Query by requestId (exact) or by serialNumber (all requests for a device).
# The response carries the technical evidence the ServiceNow process requires:
# device identifiers, dispatch/completion timestamps, Automation job id and the
# structured runbook result.

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/AT.Common.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/AT.State.psm1" -Force

function Write-Json {
    param([int] $StatusCode, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = ($Object | ConvertTo-Json -Depth 12)
    })
}

function ConvertTo-StatusView {
    param($Entity)

    $result = $null
    if ($Entity.PSObject.Properties.Name -contains 'resultJson' -and $Entity.resultJson) {
        try { $result = $Entity.resultJson | ConvertFrom-Json } catch { $result = $Entity.resultJson }
    }

    return [ordered]@{
        requestId         = $Entity.RowKey
        platform          = $Entity.PartitionKey
        correlationId     = $Entity.correlationId
        status            = $Entity.status
        scenario          = $Entity.scenario
        device            = [ordered]@{
            serialNumber    = $Entity.serialNumber
            imei            = $Entity.imei
            deviceName      = $Entity.deviceName
            managedDeviceId = $Entity.managedDeviceId
            operatingSystem = $Entity.operatingSystem
        }
        automationJobName = $Entity.automationJobName
        automationJobId   = $Entity.automationJobId
        runbook           = $Entity.runbook
        attempts          = $Entity.attempts
        acceptedAt        = $Entity.acceptedAt
        queuedAt          = $Entity.queuedAt
        dispatchedAt      = $Entity.dispatchedAt
        completedAt       = $Entity.completedAt
        errorMessage      = $Entity.errorMessage
        callbackStatus    = $Entity.callbackStatus
        result            = $result
    }
}

$requestId = [string]$Request.Query.requestId
$serialNumber = [string]$Request.Query.serialNumber

if ([string]::IsNullOrWhiteSpace($requestId) -and [string]::IsNullOrWhiteSpace($serialNumber)) {
    Write-Json -StatusCode 400 -Object @{ error = 'Provide requestId or serialNumber as a query parameter.' }
    return
}

$filter = if (-not [string]::IsNullOrWhiteSpace($requestId)) {
    "RowKey eq '$($requestId.Replace("'", "''"))'"
}
else {
    "serialNumber eq '$($serialNumber.Replace("'", "''"))'"
}

try {
    $entities = Find-WipeRequestState -Filter $filter -Top 50
}
catch {
    Write-AtLog -Level 'Error' -Message "State store query failed: $($_.Exception.Message)"
    Write-Json -StatusCode 502 -Object @{ error = 'Failed to query the state store.'; detail = $_.Exception.Message }
    return
}

if ($entities.Count -eq 0) {
    Write-Json -StatusCode 404 -Object @{ error = 'No disposal request found.'; requestId = $requestId; serialNumber = $serialNumber }
    return
}

if (-not [string]::IsNullOrWhiteSpace($requestId)) {
    Write-Json -StatusCode 200 -Object (ConvertTo-StatusView -Entity $entities[0])
    return
}

Write-Json -StatusCode 200 -Object @{
    serialNumber = $serialNumber
    count        = $entities.Count
    requests     = @($entities | ForEach-Object { ConvertTo-StatusView -Entity $_ })
}
