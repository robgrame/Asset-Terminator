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

function Get-OptionalEntityProperty {
    param(
        [Parameter(Mandatory)] $Entity,
        [Parameter(Mandatory)] [string] $Name
    )

    $property = $Entity.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-StatusView {
    param($Entity)

    $result = $null
    $resultJson = Get-OptionalEntityProperty -Entity $Entity -Name 'resultJson'
    if ($resultJson) {
        try { $result = $resultJson | ConvertFrom-Json } catch { $result = $resultJson }
    }

    return [ordered]@{
        requestId         = $Entity.RowKey
        platform          = $Entity.PartitionKey
        correlationId     = Get-OptionalEntityProperty -Entity $Entity -Name 'correlationId'
        status            = Get-OptionalEntityProperty -Entity $Entity -Name 'status'
        scenario          = Get-OptionalEntityProperty -Entity $Entity -Name 'scenario'
        device            = [ordered]@{
            serialNumber    = Get-OptionalEntityProperty -Entity $Entity -Name 'serialNumber'
            imei            = Get-OptionalEntityProperty -Entity $Entity -Name 'imei'
            deviceName      = Get-OptionalEntityProperty -Entity $Entity -Name 'deviceName'
            managedDeviceId = Get-OptionalEntityProperty -Entity $Entity -Name 'managedDeviceId'
            operatingSystem = Get-OptionalEntityProperty -Entity $Entity -Name 'operatingSystem'
        }
        automationJobName = Get-OptionalEntityProperty -Entity $Entity -Name 'automationJobName'
        automationJobId   = Get-OptionalEntityProperty -Entity $Entity -Name 'automationJobId'
        runbook           = Get-OptionalEntityProperty -Entity $Entity -Name 'runbook'
        attempts          = Get-OptionalEntityProperty -Entity $Entity -Name 'attempts'
        acceptedAt        = Get-OptionalEntityProperty -Entity $Entity -Name 'acceptedAt'
        dispatchedAt      = Get-OptionalEntityProperty -Entity $Entity -Name 'dispatchedAt'
        completedAt       = Get-OptionalEntityProperty -Entity $Entity -Name 'completedAt'
        errorMessage      = Get-OptionalEntityProperty -Entity $Entity -Name 'errorMessage'
        callbackStatus    = Get-OptionalEntityProperty -Entity $Entity -Name 'callbackStatus'
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
    "PartitionKey ne '__DeviceLease' and serialNumber eq '$($serialNumber.Replace("'", "''"))'"
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
