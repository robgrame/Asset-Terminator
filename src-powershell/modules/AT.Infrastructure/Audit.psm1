# Audit.psm1  (nested in AT.Infrastructure)
# Append-only, hash-chained immutable audit backed by Azure Blob Storage with a
# WORM (time-based retention) policy. Parity with
# AssetTerminator.Infrastructure.Audit.BlobAuditWriter.
#
# Each record is written write-once (If-None-Match: *) under "{requestId}/{seq}"
# and hash-chained to the previous record (SHA-256 over canonical content + the
# previous hash) for tamper-evidence. The hash is chain-internal: it makes the
# PowerShell audit self-verifying; it is not required to byte-match the .NET chain.
#
# Configuration (app settings):
#   AUDIT_BLOB_ACCOUNT   : storage account name (blob service)
#   AUDIT_CONTAINER      : container name (default 'audit')
#   UAMI_CLIENT_ID       : user-assigned identity client id (token audience)

Set-StrictMode -Version Latest

$script:BlobResource   = 'https://storage.azure.com/'
$script:BlobApiVersion = '2021-12-02'

function New-AuditRecord {
    <#
        .SYNOPSIS
            Builds an audit record object with normalized fields.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RequestId,
        [Parameter(Mandatory)][string] $Action,
        [string] $CorrelationId,
        [string] $TicketNumber,
        [string] $AssetId,
        [string] $TargetEnvironment,
        [string] $Actor = 'servicenow',
        [string] $Outcome,
        [string] $Reason,
        $GuardrailResults,
        [datetime] $TimestampUtc = ([datetime]::UtcNow)
    )
    [pscustomobject][ordered]@{
        correlationId     = $CorrelationId
        requestId         = $RequestId
        ticketNumber      = $TicketNumber
        assetId           = $AssetId
        action            = $Action
        targetEnvironment = $TargetEnvironment
        actor             = $Actor
        timestampUtc      = $TimestampUtc.ToUniversalTime().ToString('o')
        outcome           = $Outcome
        reason            = $Reason
        guardrailResults  = $GuardrailResults
        previousHash      = $null
        hash              = $null
    }
}

function Get-AuditHash {
    <#
        .SYNOPSIS
            Computes the SHA-256 (uppercase hex) hash over an audit record's
            canonical content plus the previous hash. Parity with ComputeHash.
        .DESCRIPTION
            Canonical field order matches the .NET writer. The Hash/PreviousHash
            fields of the record itself are excluded from the canonical content
            (PreviousHash is supplied explicitly and appended).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Record,
        [string] $PreviousHash
    )
    $canonical = [ordered]@{
        correlationId     = $Record.correlationId
        requestId         = $Record.requestId
        ticketNumber      = $Record.ticketNumber
        assetId           = $Record.assetId
        action            = $Record.action
        targetEnvironment = $Record.targetEnvironment
        actor             = $Record.actor
        timestamp         = $Record.timestampUtc
        outcome           = $Record.outcome
        reason            = $Record.reason
        guardrailResults  = $Record.guardrailResults
        previousHash      = $PreviousHash
    }
    $json  = $canonical | ConvertTo-Json -Compress -Depth 12
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '')
    }
    finally { $sha.Dispose() }
}

function ConvertTo-BlobPrefix {
    param([Parameter(Mandatory)][string] $RequestId)
    # Blob prefixes: keep letters/digits/-/_, replace the rest (parity with Sanitize).
    return (($RequestId.ToCharArray() | ForEach-Object {
        if ([char]::IsLetterOrDigit($_) -or $_ -eq '-' -or $_ -eq '_') { $_ } else { '_' }
    }) -join '')
}

function Test-AuditChain {
    <#
        .SYNOPSIS
            Verifies the hash chain of an ordered list of audit records.
        .OUTPUTS
            [pscustomobject] @{ Valid = <bool>; BrokenAt = <index or -1> }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Records)

    $prev = $null
    for ($i = 0; $i -lt $Records.Count; $i++) {
        $rec = $Records[$i]
        $expected = Get-AuditHash -Record $rec -PreviousHash $prev
        if ($rec.previousHash -ne $prev -or $rec.hash -ne $expected) {
            return [pscustomobject]@{ Valid = $false; BrokenAt = $i }
        }
        $prev = $rec.hash
    }
    return [pscustomobject]@{ Valid = $true; BrokenAt = -1 }
}

# --- Blob REST helpers (Managed Identity, no account keys) ---

function Get-AuditConfig {
    [CmdletBinding()] param()
    $account = $env:AUDIT_BLOB_ACCOUNT
    if (-not $account) { throw 'AUDIT_BLOB_ACCOUNT app setting is not configured.' }
    $container = if ($env:AUDIT_CONTAINER) { $env:AUDIT_CONTAINER } else { 'audit' }
    [pscustomobject]@{
        Account   = $account
        Container = $container
        Endpoint  = "https://$account.blob.core.windows.net"
    }
}

function Get-BlobHeaders {
    param([hashtable] $Extra)
    $token = Get-IdentityToken -Resource $script:BlobResource
    $h = @{
        Authorization  = "Bearer $token"
        'x-ms-version' = $script:BlobApiVersion
        'x-ms-date'    = [DateTime]::UtcNow.ToString('R')
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] } }
    return $h
}

function Get-AuditBlobNames {
    <#
        .SYNOPSIS
            Lists existing audit blob names under a request prefix, ordinal-sorted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RequestId)
    $cfg = Get-AuditConfig
    $prefix = (ConvertTo-BlobPrefix $RequestId) + '/'
    $uri = "$($cfg.Endpoint)/$($cfg.Container)?restype=container&comp=list&prefix=$([uri]::EscapeDataString($prefix))"
    $resp = Invoke-AtRetry -ScriptBlock { Invoke-RestMethod -Method Get -Uri $uri -Headers (Get-BlobHeaders) -ErrorAction Stop }
    $names = @()
    if ($resp -is [string]) {
        $xml = [xml]$resp
        if ($xml.EnumerationResults.Blobs.Blob) { $names = @($xml.EnumerationResults.Blobs.Blob.Name) }
    }
    return @($names | Sort-Object -CaseSensitive)
}

function Get-AuditBlob {
    param([Parameter(Mandatory)][string] $BlobName)
    $cfg = Get-AuditConfig
    $uri = "$($cfg.Endpoint)/$($cfg.Container)/$([uri]::EscapeUriString($BlobName))"
    try {
        return Invoke-RestMethod -Method Get -Uri $uri -Headers (Get-BlobHeaders) -ErrorAction Stop
    }
    catch {
        if ((Get-HttpStatus $_) -eq 404) { return $null }
        throw
    }
}

function Add-AuditRecord {
    <#
        .SYNOPSIS
            Appends a record to the request's hash chain (write-once). Parity with
            BlobAuditWriter.AppendAsync.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Record)

    $cfg = Get-AuditConfig
    $existing = Get-AuditBlobNames -RequestId $Record.requestId
    $seq = $existing.Count

    $previousHash = $null
    if ($seq -gt 0) {
        $last = Get-AuditBlob -BlobName $existing[-1]
        if ($last) { $previousHash = $last.hash }
    }

    $Record.previousHash = $previousHash
    $Record.hash = Get-AuditHash -Record $Record -PreviousHash $previousHash

    $prefix = (ConvertTo-BlobPrefix $Record.requestId) + '/'
    $tsCompact = ([datetime]$Record.timestampUtc).ToUniversalTime().ToString('yyyyMMddHHmmssfff')
    $blobName = '{0}{1:D8}-{2}.json' -f $prefix, $seq, $tsCompact
    $uri = "$($cfg.Endpoint)/$($cfg.Container)/$([uri]::EscapeUriString($blobName))"
    $body = $Record | ConvertTo-Json -Compress -Depth 12

    # Write-once: If-None-Match:* fails if the blob already exists (idempotent seq).
    $headers = Get-BlobHeaders @{ 'x-ms-blob-type' = 'BlockBlob'; 'If-None-Match' = '*'; 'Content-Type' = 'application/json' }
    Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -Body $body -ErrorAction Stop | Out-Null
    Write-AtLog -Message "Audit appended $blobName" -Properties @{ requestId = $Record.requestId; action = $Record.action; outcome = $Record.outcome }
    return $blobName
}

function Get-AuditTimeline {
    <#
        .SYNOPSIS
            Returns all audit records for a request, oldest first. Parity with ReadTimelineAsync.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RequestId)
    $names = Get-AuditBlobNames -RequestId $RequestId
    $result = foreach ($n in $names) { $r = Get-AuditBlob -BlobName $n; if ($r) { $r } }
    return @($result)
}

Export-ModuleMember -Function New-AuditRecord, Get-AuditHash, ConvertTo-BlobPrefix, Test-AuditChain, `
    Get-AuditConfig, Get-AuditBlobNames, Get-AuditBlob, Add-AuditRecord, Get-AuditTimeline
