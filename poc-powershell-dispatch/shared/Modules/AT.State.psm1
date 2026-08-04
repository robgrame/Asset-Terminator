#Requires -Version 7.6

# Durable request state on Azure Table Storage, accessed over REST with a
# managed-identity bearer token (the storage account has shared key access
# disabled). PartitionKey = platform, RowKey = requestId.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/AT.Common.psm1"

$script:TableApiVersion = '2019-02-02'

function Get-StateTableUri {
    $endpoint = (Get-AppSetting -Name 'STATE_TABLE_ENDPOINT' -Required).TrimEnd('/')
    $table = Get-AppSetting -Name 'STATE_TABLE_NAME' -Default 'wiperequests'
    return "$endpoint/$table"
}

function Get-TableHeaders {
    $token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
    return @{
        'Authorization'  = "Bearer $token"
        'x-ms-version'   = $script:TableApiVersion
        'x-ms-date'      = (Get-Date).ToUniversalTime().ToString('R')
        'Accept'         = 'application/json;odata=nometadata'
        'DataServiceVersion' = '3.0;NetFx'
        'MaxDataServiceVersion' = '3.0;NetFx'
    }
}

function Save-WipeRequestState {
    <#
    .SYNOPSIS
        Inserts or replaces the state entity for a request (idempotent upsert).
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [hashtable] $Properties
    )

    $entity = @{
        PartitionKey = $Platform
        RowKey       = $RequestId
    }
    foreach ($key in $Properties.Keys) {
        $value = $Properties[$key]
        if ($null -eq $value) { continue }
        # Table Storage has no object type: complex values are stored as JSON.
        if ($value -is [hashtable] -or $value -is [pscustomobject] -or $value -is [array]) {
            $entity[$key] = ($value | ConvertTo-Json -Depth 10 -Compress)
        }
        elseif ($value -is [datetime]) {
            $entity[$key] = $value.ToUniversalTime().ToString('o')
        }
        else {
            $entity[$key] = $value
        }
    }

    $uri = "{0}(PartitionKey='{1}',RowKey='{2}')" -f (Get-StateTableUri), $Platform, $RequestId
    $headers = Get-TableHeaders
    $headers['Content-Type'] = 'application/json'

    Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -Body ($entity | ConvertTo-Json -Depth 10) | Out-Null
    return $entity
}

function Update-WipeRequestState {
    <#
    .SYNOPSIS
        Merges a partial update into an existing state entity.
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [hashtable] $Properties
    )

    $entity = @{ PartitionKey = $Platform; RowKey = $RequestId }
    foreach ($key in $Properties.Keys) {
        $value = $Properties[$key]
        if ($null -eq $value) { continue }
        if ($value -is [hashtable] -or $value -is [pscustomobject] -or $value -is [array]) {
            $entity[$key] = ($value | ConvertTo-Json -Depth 10 -Compress)
        }
        elseif ($value -is [datetime]) {
            $entity[$key] = $value.ToUniversalTime().ToString('o')
        }
        else {
            $entity[$key] = $value
        }
    }

    $uri = "{0}(PartitionKey='{1}',RowKey='{2}')" -f (Get-StateTableUri), $Platform, $RequestId
    $headers = Get-TableHeaders
    $headers['Content-Type'] = 'application/json'
    $headers['If-Match'] = '*'

    Invoke-RestMethod -Uri $uri -Method MERGE -Headers $headers -Body ($entity | ConvertTo-Json -Depth 10) | Out-Null
}

function Get-WipeRequestState {
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestId
    )

    $uri = "{0}(PartitionKey='{1}',RowKey='{2}')" -f (Get-StateTableUri), $Platform, $RequestId
    try {
        return Invoke-RestMethod -Uri $uri -Method GET -Headers (Get-TableHeaders)
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

function Get-WipeDeviceLeaseKey {
    param([Parameter(Mandatory)] [string] $SerialNumber)

    $normalized = $SerialNumber.Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) { throw 'A serial number is required for the device lease.' }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalized))
        return [System.Convert]::ToHexString($hash).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-WipeDeviceLease {
    param([Parameter(Mandatory)] [string] $SerialNumber)

    $leaseKey = Get-WipeDeviceLeaseKey -SerialNumber $SerialNumber
    $uri = "{0}(PartitionKey='__DeviceLease',RowKey='{1}')" -f (Get-StateTableUri), $leaseKey

    try {
        $response = Invoke-WebRequest -Uri $uri -Method GET -Headers (Get-TableHeaders)
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }

    return [pscustomobject]@{
        Entity = $response.Content | ConvertFrom-Json
        ETag   = [string]$response.Headers.ETag
    }
}

function Unlock-WipeDevice {
    param(
        [Parameter(Mandatory)] [string] $SerialNumber,
        [Parameter(Mandatory)] [string] $RequestId
    )

    $lease = Get-WipeDeviceLease -SerialNumber $SerialNumber
    if (-not $lease) { return $true }
    if ([string]$lease.Entity.requestId -ne $RequestId) { return $false }
    if ([string]::IsNullOrWhiteSpace($lease.ETag)) {
        throw "Device lease for '$SerialNumber' did not include an ETag."
    }

    $leaseKey = Get-WipeDeviceLeaseKey -SerialNumber $SerialNumber
    $uri = "{0}(PartitionKey='__DeviceLease',RowKey='{1}')" -f (Get-StateTableUri), $leaseKey
    $headers = Get-TableHeaders
    $headers['If-Match'] = $lease.ETag

    try {
        Invoke-RestMethod -Uri $uri -Method DELETE -Headers $headers | Out-Null
        return $true
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -in @(404, 412)) { return $false }
        throw
    }
}

function Lock-WipeDevice {
    param(
        [Parameter(Mandatory)] [string] $SerialNumber,
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [string] $Platform,
        [int] $LeaseHours = 4
    )

    $leaseKey = Get-WipeDeviceLeaseKey -SerialNumber $SerialNumber
    $uri = Get-StateTableUri

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $now = (Get-Date).ToUniversalTime()
        $entity = @{
            PartitionKey = '__DeviceLease'
            RowKey       = $leaseKey
            serialNumber = $SerialNumber
            requestId    = $RequestId
            platform     = $Platform
            acquiredAt   = $now.ToString('o')
            expiresAt    = $now.AddHours($LeaseHours).ToString('o')
        }
        $headers = Get-TableHeaders
        $headers['Content-Type'] = 'application/json'
        $headers['Prefer'] = 'return-no-content'

        try {
            Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body ($entity | ConvertTo-Json) | Out-Null
            return [pscustomobject]@{
                Acquired       = $true
                ActiveRequestId = $RequestId
                ActivePlatform = $Platform
                ExpiresAt      = $entity.expiresAt
            }
        }
        catch {
            if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 409) { throw }
        }

        $existing = Get-WipeDeviceLease -SerialNumber $SerialNumber
        if (-not $existing) { continue }

        $expiresAt = [datetime]::MinValue
        [datetime]::TryParse([string]$existing.Entity.expiresAt, [ref]$expiresAt) | Out-Null
        if ($expiresAt.ToUniversalTime() -le $now) {
            Unlock-WipeDevice -SerialNumber $SerialNumber -RequestId ([string]$existing.Entity.requestId) | Out-Null
            continue
        }

        return [pscustomobject]@{
            Acquired        = $false
            ActiveRequestId = [string]$existing.Entity.requestId
            ActivePlatform  = [string]$existing.Entity.platform
            ExpiresAt       = [string]$existing.Entity.expiresAt
        }
    }

    throw "Unable to acquire the device lease for '$SerialNumber' after removing an expired lease."
}

function Find-WipeRequestState {
    <#
    .SYNOPSIS
        Queries the state table with an OData filter (e.g. by requestId across
        partitions, or by status for the job monitor).
    #>
    param(
        [string] $Filter,
        [int] $Top = 100
    )

    $uri = '{0}()?$top={1}' -f (Get-StateTableUri), $Top
    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $uri += '&$filter=' + [uri]::EscapeDataString($Filter)
    }

    $response = Invoke-RestMethod -Uri $uri -Method GET -Headers (Get-TableHeaders)
    if ($null -eq $response -or -not ($response.PSObject.Properties.Name -contains 'value')) { return @() }
    return @($response.value)
}

Export-ModuleMember -Function Save-WipeRequestState, Update-WipeRequestState, Get-WipeRequestState, `
    Lock-WipeDevice, Unlock-WipeDevice, Find-WipeRequestState
