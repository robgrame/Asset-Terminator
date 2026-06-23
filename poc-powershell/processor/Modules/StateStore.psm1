# StateStore.psm1
# Lightweight state persistence for the Asset-Terminator PowerShell POC backed by
# Azure Table Storage, accessed over the Table REST API with an Entra (Managed
# Identity) token -- no account keys. This replaces the Azure SQL state store of
# the full .NET solution for the subset of features the POC needs: idempotency on
# requestId and a queryable current state + a lightweight event history.
#
# Configuration (app settings):
#   STATE_TABLE_ACCOUNT : dedicated storage account name (table service)
#   STATE_TABLE_NAME    : table name (default 'DecommissionState')
#   UAMI_CLIENT_ID      : client id of the user-assigned identity (token audience)
#
# Entity model (PartitionKey = requestId):
#   RowKey 'state'              -> current overall state (upserted on each change)
#   RowKey 'evt-<sortable>-<id>'-> append-only event rows (history)

$script:StorageResource = 'https://storage.azure.com/'
$script:TableApiVersion = '2019-02-02'

function Get-StateConfig {
    [CmdletBinding()]
    param()
    $account = $env:STATE_TABLE_ACCOUNT
    if (-not $account) { throw 'STATE_TABLE_ACCOUNT app setting is not configured.' }
    $table = if ($env:STATE_TABLE_NAME) { $env:STATE_TABLE_NAME } else { 'DecommissionState' }
    return [pscustomobject]@{
        Account  = $account
        Table    = $table
        Endpoint = "https://$account.table.core.windows.net"
    }
}

function Get-TableHeaders {
    [CmdletBinding()]
    param([switch] $ReturnNoContent)
    $token = Get-IdentityToken -Resource $script:StorageResource
    $headers = @{
        Authorization    = "Bearer $token"
        'x-ms-version'   = $script:TableApiVersion
        'x-ms-date'      = [DateTime]::UtcNow.ToString('R')
        Accept           = 'application/json;odata=nometadata'
        'Content-Type'   = 'application/json'
        DataServiceVersion = '3.0;NetFx'
    }
    if ($ReturnNoContent) { $headers['Prefer'] = 'return-no-content' }
    return $headers
}

function Initialize-StateTable {
    <#
        .SYNOPSIS
            Creates the state table if it does not already exist (idempotent).
    #>
    [CmdletBinding()]
    param()
    $cfg = Get-StateConfig
    $headers = Get-TableHeaders
    $body = @{ TableName = $cfg.Table } | ConvertTo-Json
    try {
        Invoke-RestMethod -Method Post -Uri "$($cfg.Endpoint)/Tables" -Headers $headers -Body $body -ErrorAction Stop | Out-Null
    }
    catch {
        $status = $null; try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -ne 409) { throw }  # 409 = table already exists
    }
}

function ConvertTo-EntityKey {
    param([Parameter(Mandatory)][string] $Value)
    # Table keys cannot contain / \ # ? or control chars.
    return ($Value -replace '[\\/#?\u0000-\u001F\u007F-\u009F]', '_')
}

function Get-DecommissionState {
    <#
        .SYNOPSIS
            Returns the current state entity for a requestId, or $null if absent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RequestId)

    $cfg = Get-StateConfig
    $pk = ConvertTo-EntityKey $RequestId
    $uri = "$($cfg.Endpoint)/$($cfg.Table)(PartitionKey='$pk',RowKey='state')"
    try {
        return Invoke-RestMethod -Method Get -Uri $uri -Headers (Get-TableHeaders) -ErrorAction Stop
    }
    catch {
        $status = $null; try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 404) { return $null }
        throw
    }
}

function Get-DecommissionHistory {
    <#
        .SYNOPSIS
            Returns the event rows (history) for a requestId, oldest first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RequestId)

    $cfg = Get-StateConfig
    $pk = ConvertTo-EntityKey $RequestId
    $filter = [Uri]::EscapeDataString("PartitionKey eq '$pk' and RowKey ge 'evt-' and RowKey lt 'evu'")
    $uri = "$($cfg.Endpoint)/$($cfg.Table)()?`$filter=$filter"
    try {
        $result = Invoke-RestMethod -Method Get -Uri $uri -Headers (Get-TableHeaders) -ErrorAction Stop
        return @($result.value | Sort-Object RowKey)
    }
    catch {
        $status = $null; try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 404) { return @() }
        throw
    }
}

function Set-DecommissionState {
    <#
        .SYNOPSIS
            Upserts the current-state row and appends an event row (history).
        .DESCRIPTION
            InsertOrReplace via PUT. The CreatedAt is preserved across updates by
            the caller if needed; here we always set LastUpdatedAt and append an
            event capturing the new status + detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RequestId,
        [Parameter(Mandatory)][string] $Status,
        [hashtable] $Properties = @{}
    )

    $cfg = Get-StateConfig
    $pk = ConvertTo-EntityKey $RequestId
    $now = [DateTime]::UtcNow.ToString('o')

    $entity = @{
        PartitionKey  = $pk
        RowKey        = 'state'
        RequestId     = $RequestId
        OverallStatus = $Status
        LastUpdatedAt = $now
    }
    foreach ($k in $Properties.Keys) { $entity[$k] = $Properties[$k] }
    if (-not $entity.ContainsKey('CreatedAt')) { $entity['CreatedAt'] = $now }

    $stateUri = "$($cfg.Endpoint)/$($cfg.Table)(PartitionKey='$pk',RowKey='state')"
    Invoke-RestMethod -Method Put -Uri $stateUri -Headers (Get-TableHeaders -ReturnNoContent) `
        -Body ($entity | ConvertTo-Json -Depth 6) -ErrorAction Stop | Out-Null

    # Append-only event row. RowKey is time-sortable for ordered history.
    $rowKey = "evt-{0}-{1}" -f [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $event = @{
        PartitionKey  = $pk
        RowKey        = $rowKey
        RequestId     = $RequestId
        OverallStatus = $Status
        Timestamp_    = $now
    }
    foreach ($k in $Properties.Keys) { $event[$k] = $Properties[$k] }
    $eventUri = "$($cfg.Endpoint)/$($cfg.Table)(PartitionKey='$pk',RowKey='$rowKey')"
    Invoke-RestMethod -Method Put -Uri $eventUri -Headers (Get-TableHeaders -ReturnNoContent) `
        -Body ($event | ConvertTo-Json -Depth 6) -ErrorAction Stop | Out-Null
}

function New-DecommissionStateIfAbsent {
    <#
        .SYNOPSIS
            Idempotency guard: atomically creates the initial state row only if it
            does not already exist.
        .OUTPUTS
            [pscustomobject] @{ Created = <bool>; Entity = <existing or new state> }
            When Created is $false the request is a duplicate and the existing
            state is returned (so the caller can skip re-enqueuing).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RequestId,
        [Parameter(Mandatory)][string] $Status,
        [hashtable] $Properties = @{}
    )

    $cfg = Get-StateConfig
    $pk = ConvertTo-EntityKey $RequestId
    $now = [DateTime]::UtcNow.ToString('o')

    $entity = @{
        PartitionKey  = $pk
        RowKey        = 'state'
        RequestId     = $RequestId
        OverallStatus = $Status
        CreatedAt     = $now
        LastUpdatedAt = $now
    }
    foreach ($k in $Properties.Keys) { $entity[$k] = $Properties[$k] }

    # POST to the table performs an Insert; 409 Conflict => entity already exists.
    $insertUri = "$($cfg.Endpoint)/$($cfg.Table)"
    try {
        Invoke-RestMethod -Method Post -Uri $insertUri -Headers (Get-TableHeaders -ReturnNoContent) `
            -Body ($entity | ConvertTo-Json -Depth 6) -ErrorAction Stop | Out-Null
        # Mirror the creation as an event row for history.
        Set-DecommissionState -RequestId $RequestId -Status $Status -Properties $Properties
        return [pscustomobject]@{ Created = $true; Entity = $entity }
    }
    catch {
        $status = $null; try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 409) {
            return [pscustomobject]@{ Created = $false; Entity = (Get-DecommissionState -RequestId $RequestId) }
        }
        throw
    }
}

Export-ModuleMember -Function Initialize-StateTable, Get-DecommissionState, Get-DecommissionHistory, `
    Set-DecommissionState, New-DecommissionStateIfAbsent
