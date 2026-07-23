# AT.Api.Support.psm1
# Config binding + HTTP helpers for the API Function App. Reads the hierarchical
# AssetTerminator__* app settings (double-underscore) into option objects, mirroring
# the .NET Options binding (IngestionOptions, PreWipeOptions, OverrideOptions).

Set-StrictMode -Version Latest

function Get-ConfigValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Key, [string] $Default)
    $v = [Environment]::GetEnvironmentVariable($Key)
    if ([string]::IsNullOrEmpty($v)) { return $Default }
    return $v
}

function Get-ConfigBool {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Key, [bool] $Default)
    $v = [Environment]::GetEnvironmentVariable($Key)
    if ([string]::IsNullOrEmpty($v)) { return $Default }
    $parsed = $false
    if ([bool]::TryParse($v, [ref]$parsed)) { return $parsed }
    return $Default
}

function Get-ConfigList {
    <#
        .SYNOPSIS
            Reads a config list from either 'Key' (semicolon/comma separated) or the
            indexed form 'Key__0','Key__1',... (as emitted by .NET config providers).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Key)
    $items = [System.Collections.Generic.List[string]]::new()
    $flat = [Environment]::GetEnvironmentVariable($Key)
    if (-not [string]::IsNullOrWhiteSpace($flat)) {
        foreach ($p in ($flat -split '[;,]')) { $t = $p.Trim(); if ($t) { $items.Add($t) } }
    }
    $i = 0
    while ($true) {
        $val = [Environment]::GetEnvironmentVariable("${Key}__$i")
        if ([string]::IsNullOrEmpty($val)) { break }
        $items.Add($val.Trim())
        $i++
    }
    return , $items.ToArray()
}

function Get-IngestionOptions {
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        apiKeyHeader = Get-ConfigValue -Key 'AssetTerminator__Ingestion__ApiKeyHeader' -Default 'x-api-key'
        apiKeys      = Get-ConfigList  -Key 'AssetTerminator__Ingestion__ApiKeys'
        ipAllowlist  = Get-ConfigList  -Key 'AssetTerminator__Ingestion__IpAllowlist'
    }
}

function Get-PreWipeOptions {
    [CmdletBinding()]
    param()
    @{
        DeleteFromAutopilot     = Get-ConfigBool -Key 'AssetTerminator__PreWipe__DeleteFromAutopilot' -Default $true
        RemoveEnterpriseLicense = Get-ConfigBool -Key 'AssetTerminator__PreWipe__RemoveEnterpriseLicense' -Default $true
        RemoveBiosPassword      = Get-ConfigBool -Key 'AssetTerminator__PreWipe__RemoveBiosPassword' -Default $true
    }
}

function Get-OverrideRequiredFor {
    <# Parity with OverrideOptions.RequiredFor: default Standard=1, Vip=2, Critical=2. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $AssetCategory)
    $default = switch ($AssetCategory) { 'Vip' { 2 } 'Critical' { 2 } default { 1 } }
    $raw = [Environment]::GetEnvironmentVariable("AssetTerminator__Override__RequiredApprovals__$AssetCategory")
    $parsed = 0
    if (-not [string]::IsNullOrEmpty($raw) -and [int]::TryParse($raw, [ref]$parsed)) {
        return [Math]::Max(1, $parsed)
    }
    return $default
}

function Write-HttpJson {
    <# Pushes a JSON HTTP response through the 'Response' output binding. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int] $StatusCode, [Parameter(Mandatory)] $Body, [hashtable] $Headers)
    $h = @{ 'Content-Type' = 'application/json' }
    if ($Headers) { foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] } }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Headers    = $h
            Body       = ($Body | ConvertTo-Json -Depth 8)
        })
}

function ConvertTo-RequestObject {
    <# Normalizes the Functions request body (string or parsed) into a PSObject, or $null. #>
    [CmdletBinding()]
    param($Body)
    if ($null -eq $Body) { return $null }
    if ($Body -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
        try { return $Body | ConvertFrom-Json } catch { return $null }
    }
    if ($Body -is [byte[]]) {
        try { return ([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json) } catch { return $null }
    }
    return $Body
}

function ConvertTo-StatusResponse {
    <# Maps a SQL request row (+ its actions) to the public status contract. Parity with ApiMappings.ToStatus. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Record)
    $actions = @(Get-OptionalProp $Record 'actions') | Sort-Object { [string](Get-OptionalProp $_ 'Target') } | ForEach-Object {
        [pscustomobject]@{
            target      = Get-OptionalProp $_ 'Target'
            action      = Get-OptionalProp $_ 'Action'
            status      = [string](Get-OptionalProp $_ 'Status')
            lastChecked = Get-OptionalProp $_ 'LastUpdatedUtc'
            retryCount  = Get-OptionalProp $_ 'Attempts'
            details     = Get-OptionalProp $_ 'FinalOutcome'
        }
    }
    [pscustomobject]@{
        requestId     = Get-OptionalProp $Record 'RequestId'
        correlationId = Get-OptionalProp $Record 'CorrelationId'
        ticketNumber  = Get-OptionalProp $Record 'TicketNumber'
        overallStatus = [string](Get-OptionalProp $Record 'State')
        slaState      = [string](Get-OptionalProp $Record 'SlaState')
        createdAt     = Get-OptionalProp $Record 'CreatedAtUtc'
        lastUpdatedAt = Get-OptionalProp $Record 'LastUpdatedAtUtc'
        dueAt         = Get-OptionalProp $Record 'DueAtUtc'
        actions       = @($actions)
    }
}

function ConvertTo-HistoryEvent {
    <# Maps an immutable audit record to a public history event. Parity with ApiMappings.ToHistory. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Audit)
    [pscustomobject]@{
        timestamp = Get-OptionalProp $Audit 'timestampUtc'
        eventType = Get-OptionalProp $Audit 'action'
        target    = Get-OptionalProp $Audit 'targetEnvironment'
        outcome   = Get-OptionalProp $Audit 'outcome'
        actor     = Get-OptionalProp $Audit 'actor'
        detail    = Get-OptionalProp $Audit 'reason'
    }
}

Export-ModuleMember -Function Get-ConfigValue, Get-ConfigBool, Get-ConfigList, Get-IngestionOptions, `
    Get-PreWipeOptions, Get-OverrideRequiredFor, Write-HttpJson, ConvertTo-RequestObject, `
    ConvertTo-StatusResponse, ConvertTo-HistoryEvent
