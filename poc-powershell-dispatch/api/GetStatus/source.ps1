#Requires -Version 7.6

using namespace System.Net

# GetStatus handler - returns the durable state of a disposal request.
#
# Query by requestId (exact) or by serialNumber (all requests for a device).
# The response carries the technical evidence the ServiceNow process requires:
# device identifiers, dispatch/completion timestamps, Automation job id and the
# structured runbook result.

param($Request, $TriggerMetadata)

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
    $resultJson = Get-JsonPropertyValue -InputObject $Entity -Name 'resultJson'
    if ($resultJson) {
        try { $result = $resultJson | ConvertFrom-Json } catch { $result = $resultJson }
    }

    return [ordered]@{
        requestId         = $Entity.RowKey
        platform          = $Entity.PartitionKey
        correlationId     = Get-JsonPropertyValue -InputObject $Entity -Name 'correlationId'
        status            = Get-JsonPropertyValue -InputObject $Entity -Name 'status'
        reason            = Get-JsonPropertyValue -InputObject $Entity -Name 'reason'
        scenario          = Get-JsonPropertyValue -InputObject $Entity -Name 'scenario'
        payloadHash       = Get-JsonPropertyValue -InputObject $Entity -Name 'payloadHash'
        device            = [ordered]@{
            serialNumber    = Get-JsonPropertyValue -InputObject $Entity -Name 'serialNumber'
            imei            = Get-JsonPropertyValue -InputObject $Entity -Name 'imei'
            deviceName      = Get-JsonPropertyValue -InputObject $Entity -Name 'deviceName'
            managedDeviceId = Get-JsonPropertyValue -InputObject $Entity -Name 'managedDeviceId'
            operatingSystem = Get-JsonPropertyValue -InputObject $Entity -Name 'operatingSystem'
        }
        runbook           = Get-JsonPropertyValue -InputObject $Entity -Name 'runbook'
        automationJobName = Get-JsonPropertyValue -InputObject $Entity -Name 'automationJobName'
        automationJobId   = Get-JsonPropertyValue -InputObject $Entity -Name 'automationJobId'
        dispatchOutcome   = Get-JsonPropertyValue -InputObject $Entity -Name 'dispatchOutcome'
        attempts          = Get-JsonPropertyValue -InputObject $Entity -Name 'attempts'
        nextAttemptAt     = Get-JsonPropertyValue -InputObject $Entity -Name 'nextAttemptAt'
        evidenceState     = Get-JsonPropertyValue -InputObject $Entity -Name 'evidenceState'
        evidenceAttempts  = Get-JsonPropertyValue -InputObject $Entity -Name 'evidenceAttempts'
        # 'queuedAt' is kept alongside 'acceptedAt' for compatibility with the
        # earlier Service-Bus-queue based architecture, whose consumers expect
        # a 'queuedAt' timestamp: both fields always carry the same value.
        acceptedAt        = Get-JsonPropertyValue -InputObject $Entity -Name 'acceptedAt'
        queuedAt          = Get-JsonPropertyValue -InputObject $Entity -Name 'acceptedAt'
        dispatchedAt      = Get-JsonPropertyValue -InputObject $Entity -Name 'dispatchedAt'
        completedAt       = Get-JsonPropertyValue -InputObject $Entity -Name 'completedAt'
        errorMessage      = Get-JsonPropertyValue -InputObject $Entity -Name 'errorMessage'
        eventId           = Get-JsonPropertyValue -InputObject $Entity -Name 'eventId'
        callbackStatus    = Get-JsonPropertyValue -InputObject $Entity -Name 'callbackStatus'
        callbackAttempts  = Get-JsonPropertyValue -InputObject $Entity -Name 'callbackAttempts'
        callbackNextAttemptAt = Get-JsonPropertyValue -InputObject $Entity -Name 'callbackNextAttemptAt'
        callbackError     = Get-JsonPropertyValue -InputObject $Entity -Name 'callbackError'
        result            = $result
    }
}

$requestId = [string](Get-JsonPropertyValue -InputObject $Request.Query -Name 'requestId')
$serialNumber = [string](Get-JsonPropertyValue -InputObject $Request.Query -Name 'serialNumber')

if ([string]::IsNullOrWhiteSpace($requestId) -and [string]::IsNullOrWhiteSpace($serialNumber)) {
    Write-Json -StatusCode 400 -Object @{ error = 'Provide requestId or serialNumber as a query parameter.' }
    return
}

$filter = if (-not [string]::IsNullOrWhiteSpace($requestId)) {
    # The '__RequestId' partition also uses requestId as its RowKey (the atomic
    # idempotency index written by WipeIntake): it must never be returned here.
    "PartitionKey ne '__RequestId' and RowKey eq '$($requestId.Replace("'", "''"))'"
}
else {
    "PartitionKey ne '__DeviceLease' and PartitionKey ne '__RequestId' and serialNumber eq '$($serialNumber.Replace("'", "''"))'"
}

try {
    $entities = @(Find-WipeRequestState -Filter $filter -Top 50)
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
