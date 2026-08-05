#Requires -Version 7.6

using namespace System.Net

# GetStatus handler - returns the durable state of a disposal request.
#
# Query by requestId (exact) or by serialNumber (all requests for a device).
# The response carries the technical evidence the ServiceNow process requires:
# device identifiers, dispatch/completion timestamps, Automation job id and the
# structured runbook result.

param($Request, $TriggerMetadata)

# -----------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT DIRECTLY.
# Trigger source: source.ps1
# Shared sources: ../../shared/Modules/*.psm1
# Regenerate with: ./build.ps1 -Clean
# -----------------------------------------------------------------------------

# region Inlined functions from: AT.Common.psm1
# Shared helpers for the Asset-Terminator dispatch PoC:
# app settings, structured logging, managed-identity tokens, platform mapping
# and a minimal JSON path resolver used by the runbook parameter binding.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TokenCache = @{}

function Get-AppSetting {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $Default = $null,
        [switch] $Required
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Required) { throw "Application setting '$Name' is not configured." }
        return $Default
    }
    return $value
}

function Get-AppSettingBool {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [bool] $Default = $false
    )

    $value = Get-AppSetting -Name $Name
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }

    $parsed = $false
    if ([bool]::TryParse($value, [ref] $parsed)) { return $parsed }
    return $Default
}

function Get-AppSettingInt {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [int] $Default = 0
    )

    $value = Get-AppSetting -Name $Name
    $parsed = 0
    if ([int]::TryParse($value, [ref] $parsed)) { return $parsed }
    return $Default
}

function Write-AtLog {
    param(
        [ValidateSet('Information', 'Warning', 'Error')] [string] $Level = 'Information',
        [Parameter(Mandatory)] [string] $Message,
        [hashtable] $Properties
    )

    $entry = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        level     = $Level
        message   = $Message
    }

    if ($Properties) {
        foreach ($key in $Properties.Keys) {
            if ($null -ne $Properties[$key] -and "$($Properties[$key])" -ne '') {
                $entry[$key] = $Properties[$key]
            }
        }
    }

    $line = ($entry | ConvertTo-Json -Depth 6 -Compress)

    switch ($Level) {
        'Error'   { Write-Error $line -ErrorAction Continue }
        'Warning' { Write-Warning $line }
        default   { Write-Information $line -InformationAction Continue }
    }
}

# ---------------------------------------------------------------------------
# Application Insights audit trail
# ---------------------------------------------------------------------------
# Audit events are posted straight to the App Insights ingestion endpoint as
# customEvents (and optionally traces). This bypasses the Functions host
# sampling, so an audit record is never dropped, and gives ServiceNow / the SOC
# a queryable, immutable trail of every meaningful action in the pipeline.
#
# The same wire contract is reused verbatim by the runbooks (which run in Azure
# Automation, outside the Functions host) so the whole flow lands in one place.

function Get-AppInsightsConfig {
    # Parse 'InstrumentationKey=..;IngestionEndpoint=https://..;' into a hashtable.
    $conn = Get-AppSetting -Name 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    if ([string]::IsNullOrWhiteSpace($conn)) { return $null }

    $map = @{}
    foreach ($part in $conn.Split(';')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $kv = $part.Split('=', 2)
        if ($kv.Count -eq 2) { $map[$kv[0].Trim()] = $kv[1].Trim() }
    }

    if (-not $map.ContainsKey('InstrumentationKey')) { return $null }

    $endpoint = if ($map.ContainsKey('IngestionEndpoint')) { $map['IngestionEndpoint'] } else { 'https://dc.services.visualstudio.com/' }
    if (-not $endpoint.EndsWith('/')) { $endpoint += '/' }

    return @{
        InstrumentationKey = $map['InstrumentationKey']
        TrackUri           = "${endpoint}v2/track"
        RoleName           = (Get-AppSetting -Name 'WEBSITE_SITE_NAME' -Default 'asset-terminator')
    }
}

function Send-AppInsightsTelemetry {
    param(
        [Parameter(Mandatory)] [ValidateSet('Event', 'Trace')] [string] $Kind,
        [Parameter(Mandatory)] [string] $Name,
        [hashtable] $Properties,
        [ValidateSet('Information', 'Warning', 'Error')] [string] $Level = 'Information',
        [string] $OperationId,
        $Config
    )

    # Telemetry must never break the pipeline: swallow every error.
    try {
        if (-not $Config) { $Config = Get-AppInsightsConfig }
        if (-not $Config) { return }

        $props = @{}
        if ($Properties) {
            foreach ($key in $Properties.Keys) {
                $value = $Properties[$key]
                if ($null -ne $value -and "$value" -ne '') { $props[$key] = "$value" }
            }
        }

        $tags = @{ 'ai.cloud.role' = $Config.RoleName }
        if (-not [string]::IsNullOrWhiteSpace($OperationId)) { $tags['ai.operation.id'] = $OperationId }

        if ($Kind -eq 'Event') {
            $baseType = 'EventData'
            $baseData = @{ ver = 2; name = $Name; properties = $props }
        }
        else {
            $severity = switch ($Level) { 'Error' { 3 } 'Warning' { 2 } default { 1 } }
            $baseType = 'MessageData'
            $baseData = @{ ver = 2; message = $Name; severityLevel = $severity; properties = $props }
        }

        $envelope = @{
            name = "Microsoft.ApplicationInsights.$($Kind)"
            time = (Get-Date).ToUniversalTime().ToString('o')
            iKey = $Config.InstrumentationKey
            tags = $tags
            data = @{ baseType = $baseType; baseData = $baseData }
        }

        Invoke-RestMethod -Uri $Config.TrackUri -Method POST -ContentType 'application/json' `
            -Body ($envelope | ConvertTo-Json -Depth 10 -Compress) -TimeoutSec 10 | Out-Null
    }
    catch {
        # Never rethrow: log locally so the failure is at least visible.
        Write-Warning "App Insights telemetry '$Name' failed: $($_.Exception.Message)"
    }
}

# Emit one audit record: a structured local log line (-> AI traces via the
# Functions host) AND an immutable customEvent (-> AI customEvents table).
function Write-AtAudit {
    param(
        [Parameter(Mandatory)] [string] $Action,
        [hashtable] $Properties,
        [ValidateSet('Information', 'Warning', 'Error')] [string] $Level = 'Information'
    )

    $auditProps = @{ auditAction = $Action }
    if ($Properties) {
        foreach ($key in $Properties.Keys) { $auditProps[$key] = $Properties[$key] }
    }

    Write-AtLog -Level $Level -Message "AUDIT: $Action" -Properties $auditProps

    $operationId = $null
    if ($Properties -and $Properties.ContainsKey('correlationId')) { $operationId = [string]$Properties['correlationId'] }

    Send-AppInsightsTelemetry -Kind 'Event' -Name $Action -Properties $auditProps -Level $Level -OperationId $operationId
}

# ---------------------------------------------------------------------------
# Managed identity tokens (Functions IDENTITY_ENDPOINT protocol)
# ---------------------------------------------------------------------------
function Get-ManagedIdentityToken {
    param(
        [Parameter(Mandatory)] [string] $Resource,
        [switch] $Force
    )

    $cached = $script:TokenCache[$Resource]
    if (-not $Force -and $cached -and $cached.ExpiresOn -gt (Get-Date).AddMinutes(5)) {
        return $cached.Token
    }

    $identityEndpoint = Get-AppSetting -Name 'IDENTITY_ENDPOINT'
    $identityHeader = Get-AppSetting -Name 'IDENTITY_HEADER'
    if ([string]::IsNullOrWhiteSpace($identityEndpoint)) {
        throw 'IDENTITY_ENDPOINT is not available: the app has no managed identity assigned.'
    }

    $uri = "$identityEndpoint" + "?resource=$([uri]::EscapeDataString($Resource))&api-version=2019-08-01"

    $clientId = Get-AppSetting -Name 'UAMI_CLIENT_ID'
    if (-not [string]::IsNullOrWhiteSpace($clientId)) {
        $uri += "&client_id=$([uri]::EscapeDataString($clientId))"
    }

    $response = Invoke-RestMethod -Uri $uri -Method GET -Headers @{ 'X-IDENTITY-HEADER' = $identityHeader }

    $expiresOn = (Get-Date).AddMinutes(50)
    if ($response.PSObject.Properties.Name -contains 'expires_on') {
        $epoch = 0L
        if ([long]::TryParse("$($response.expires_on)", [ref] $epoch)) {
            $expiresOn = [DateTimeOffset]::FromUnixTimeSeconds($epoch).LocalDateTime
        }
    }

    $script:TokenCache[$Resource] = @{ Token = $response.access_token; ExpiresOn = $expiresOn }
    return $response.access_token
}

# ---------------------------------------------------------------------------
# Platform mapping
# ---------------------------------------------------------------------------

# ServiceNow speaks in operating systems (Windows / Mac / Mobile); the pipeline
# routes on the *enrollment platform* (Windows -> Autopilot, Apple -> ABM,
# Android -> Samsung KME / Zero-Touch).
function ConvertTo-EnrollmentPlatform {
    param([string] $OperatingSystem)

    if ([string]::IsNullOrWhiteSpace($OperatingSystem)) { return $null }

    switch ($OperatingSystem.Trim().ToLowerInvariant()) {
        { $_ -in @('windows', 'win', 'windows10', 'windows11') } { return 'Windows' }
        { $_ -in @('mac', 'macos', 'osx', 'ios', 'ipados', 'apple') } { return 'Apple' }
        { $_ -in @('android', 'androidenterprise') } { return 'Android' }
        # 'Mobile' is ambiguous: the intake resolves it against Intune before publishing.
        { $_ -in @('mobile') } { return 'Mobile' }
        default { return $null }
    }
}

function ConvertTo-ValidScenario {
    param([string] $Scenario)

    if ([string]::IsNullOrWhiteSpace($Scenario)) { return 'Disposal' }

    switch ($Scenario.Trim().ToLowerInvariant()) {
        { $_ -in @('retirement', 'ritiro', 'retire') } { return 'Retirement' }
        { $_ -in @('sale', 'vendita') } { return 'Sale' }
        { $_ -in @('disposal', 'smaltimento', 'dismissione') } { return 'Disposal' }
        { $_ -in @('loststolen', 'lost', 'stolen', 'furto', 'smarrimento') } { return 'LostStolen' }
        default { return $null }
    }
}

# Only Sale and Disposal remove the device from its enrollment platform;
# Retirement keeps it enrolled so the asset can be reused.
function Test-RemoveFromEnrollmentPlatform {
    param([Parameter(Mandatory)] [string] $Scenario)
    return $Scenario -in @('Sale', 'Disposal')
}

# ---------------------------------------------------------------------------
# Minimal '$.a.b' resolver used by RUNBOOK_MAP parameter binding
# ---------------------------------------------------------------------------
function Resolve-JsonPath {
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not $Path.StartsWith('$.')) { return $Path }

    $current = $InputObject
    foreach ($segment in $Path.Substring(2).Split('.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $null }
            $current = $current[$segment]
        }
        else {
            $property = $current.PSObject.Properties[$segment]
            if ($null -eq $property) { return $null }
            $current = $property.Value
        }
    }
    return $current
}

function ConvertTo-CanonicalJson {
    <#
    .SYNOPSIS
        Serialises an object to JSON with object keys sorted, so two logically
        equal payloads always produce the same text regardless of property order.
    #>
    param([Parameter(Mandatory)] $InputObject)

    if ($null -eq $InputObject) { return 'null' }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $names = @($InputObject.Keys) | Sort-Object
        $parts = foreach ($name in $names) {
            '"{0}":{1}' -f $name, (ConvertTo-CanonicalJson -InputObject $InputObject[$name])
        }
        return '{' + ($parts -join ',') + '}'
    }

    if ($InputObject -is [string]) {
        return ($InputObject | ConvertTo-Json -Compress)
    }

    if ($InputObject -is [bool]) {
        return $InputObject.ToString().ToLowerInvariant()
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $parts = foreach ($item in $InputObject) { ConvertTo-CanonicalJson -InputObject $item }
        return '[' + ($parts -join ',') + ']'
    }

    if ($InputObject -is [pscustomobject]) {
        $names = @($InputObject.PSObject.Properties.Name) | Sort-Object
        $parts = foreach ($name in $names) {
            '"{0}":{1}' -f $name, (ConvertTo-CanonicalJson -InputObject $InputObject.PSObject.Properties[$name].Value)
        }
        return '{' + ($parts -join ',') + '}'
    }

    # Numbers and other primitives.
    return ($InputObject | ConvertTo-Json -Compress)
}

function Get-PayloadHash {
    <#
    .SYNOPSIS
        Deterministic SHA-256 hex digest of the parts of a request that define
        "the same request": used to tell a safe replay (same requestId, same
        content) from a requestId collision with different content.
    #>
    param([Parameter(Mandatory)] $InputObject)

    $canonical = ConvertTo-CanonicalJson -InputObject $InputObject
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canonical))
        return [System.Convert]::ToHexString($hash).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Retry backoff
# ---------------------------------------------------------------------------
function Get-BackoffDelaySeconds {
    <#
    .SYNOPSIS
        Exponential backoff with a cap, used for both dispatch retries and
        callback retries: BaseSeconds * 2^(Attempt-1), capped at MaxSeconds.
    #>
    param(
        [Parameter(Mandatory)] [int] $Attempt,
        [int] $BaseSeconds = 15,
        [int] $MaxSeconds = 1800
    )

    if ($Attempt -lt 1) { $Attempt = 1 }
    $delay = $BaseSeconds * [Math]::Pow(2, ($Attempt - 1))
    if ($delay -gt $MaxSeconds -or [double]::IsInfinity($delay)) { $delay = $MaxSeconds }
    return [int]$delay
}

function Get-HttpErrorStatusCode {
    <#
    .SYNOPSIS
        Best-effort extraction of the HTTP status code from a terminating error
        raised by Invoke-RestMethod/Invoke-WebRequest. Returns $null when the
        error has no HTTP response at all (e.g. a network timeout or DNS
        failure), which callers must treat as "unknown", not as any specific
        status.
    #>
    param($ErrorRecord)

    try {
        if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    }
    catch { }
    return $null
}

function ConvertFrom-JsonBody {
    param($Body)

    if ($null -eq $Body) { return $null }
    if ($Body -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
        try { return $Body | ConvertFrom-Json } catch { return $null }
    }
    if ($Body -is [byte[]]) {
        try { return [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json } catch { return $null }
    }
    return $Body
}

function Get-JsonPropertyValue {
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]$key -ieq $Name) { return $InputObject[$key] }
        }
        return $null
    }

    if ($InputObject.GetType().FullName -eq 'Newtonsoft.Json.Linq.JObject') {
        $token = $InputObject[$Name]
        if ($null -eq $token) { return $null }
        $valueProperty = $token.PSObject.Properties['Value']
        if ($null -ne $valueProperty) { return $valueProperty.Value }
        return $token
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
# endregion Inlined functions from: AT.Common.psm1
# region Inlined functions from: AT.State.psm1
# Durable request state on Azure Table Storage, accessed over REST with a
# managed-identity bearer token (the storage account has shared key access
# disabled). PartitionKey = platform, RowKey = requestId.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


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

function Get-WipeRequestStateWithETag {
    <#
    .SYNOPSIS
        Reads a state entity together with its ETag, so a caller can later apply
        an optimistic-concurrency (If-Match) update: this is the read half of the
        atomic "claim" used by JobMonitor to pick up a request without racing
        another instance.
    .OUTPUTS
        PSCustomObject with Entity and ETag, or $null when the row does not exist.
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestId
    )

    $uri = "{0}(PartitionKey='{1}',RowKey='{2}')" -f (Get-StateTableUri), $Platform, $RequestId
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

function Set-WipeRequestStateClaim {
    <#
    .SYNOPSIS
        Atomically claims a request row: merges Properties only if the row's
        ETag still matches (If-Match). Returns $false instead of throwing when
        another instance already claimed/modified the row first (HTTP 412), so
        the caller can simply skip the row on this pass.
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [string] $ETag,
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
    $headers['If-Match'] = $ETag

    try {
        Invoke-RestMethod -Uri $uri -Method MERGE -Headers $headers -Body ($entity | ConvertTo-Json -Depth 10) | Out-Null
        return $true
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 412) { return $false }
        throw
    }
}

# ---------------------------------------------------------------------------
# Global requestId index (PartitionKey = '__RequestId')
# ---------------------------------------------------------------------------
# A dedicated partition maps requestId -> {platform, payloadHash} using a plain
# Table Storage INSERT (POST), which the service itself makes conditional: two
# concurrent inserts for the same RowKey can never both succeed, so this row is
# a safe, race-free idempotency gate independent of the per-platform partition
# used for the request state itself.
function Register-RequestIdIndex {
    <#
    .SYNOPSIS
        Atomically registers a requestId exactly once. A second registration
        with the *same* payload hash is treated as a safe replay (returns the
        first registration, Registered=$false, Conflict=$false). A second
        registration with a *different* hash is a genuine collision and never
        overwrites the original (Conflict=$true).
    .OUTPUTS
        PSCustomObject: Registered (bool, true only the first time), Conflict
        (bool), Platform (string, the platform the requestId was first seen
        with) and PayloadHash (string, the first-seen hash).
    #>
    param(
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $PayloadHash
    )

    $entity = @{
        PartitionKey = '__RequestId'
        RowKey       = $RequestId
        platform     = $Platform
        payloadHash  = $PayloadHash
        registeredAt = (Get-Date).ToUniversalTime().ToString('o')
    }

    $uri = Get-StateTableUri
    $headers = Get-TableHeaders
    $headers['Content-Type'] = 'application/json'

    try {
        Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body ($entity | ConvertTo-Json) | Out-Null
        return [pscustomobject]@{
            Registered  = $true
            Conflict    = $false
            Platform    = $Platform
            PayloadHash = $PayloadHash
        }
    }
    catch {
        if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 409) { throw }
    }

    # Someone (possibly this same caller, replaying) already registered this
    # requestId: read it back and let the caller decide same-payload vs conflict.
    $existing = Get-RequestIdIndex -RequestId $RequestId
    if (-not $existing) {
        # Extremely unlikely race (registered then deleted): surface as a conflict
        # so the caller does not silently proceed as if it owned the requestId.
        return [pscustomobject]@{ Registered = $false; Conflict = $true; Platform = $null; PayloadHash = $null }
    }

    $isConflict = [string]$existing.payloadHash -ne $PayloadHash
    return [pscustomobject]@{
        Registered  = $false
        Conflict    = $isConflict
        Platform    = [string]$existing.platform
        PayloadHash = [string]$existing.payloadHash
    }
}

function Get-RequestIdIndex {
    param([Parameter(Mandatory)] [string] $RequestId)

    $uri = "{0}(PartitionKey='__RequestId',RowKey='{1}')" -f (Get-StateTableUri), $RequestId
    try {
        return Invoke-RestMethod -Uri $uri -Method GET -Headers (Get-TableHeaders)
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

function Remove-RequestIdIndex {
    <#
    .SYNOPSIS
        Idempotent, conditional cleanup of a __RequestId index row: used ONLY
        to undo a registration this same caller just made, when a failure
        happens strictly before any durable Accepted/Rejected state row could
        be written for that requestId.
    .DESCRIPTION
        Without this, a pre-persistence infrastructure failure (Graph down,
        the device lease store unreachable, the initial state PUT itself
        failing, a Rejected-state persist failing, ...) would leave the index
        permanently registered with no state row behind it: every future
        retry of the exact same payload would then match the "safe replay"
        branch of Register-RequestIdIndex, find no state row, and hang
        forever on a hollow 202 "in flight" response that nothing is actually
        processing.

        Conditional on PayloadHash so it can never remove a genuinely
        different registration that raced in for the same requestId (that is
        a real conflict, not this caller's own row, and must be left alone).
        Uses an ETag-conditional DELETE (optimistic concurrency) so a
        concurrent change to the row between the read and the delete is never
        blindly overwritten.

        Idempotent: already-gone (404 on read) and already-changed-since-our-
        read (412 on delete) both count as "nothing left for this caller to
        clean up" and return $true, so this is always safe to call more than
        once (e.g. a retry of the failure path itself).
    .OUTPUTS
        $true when the row is gone (removed by this call, already absent, or
        raced away from under us); $false only when a row still exists and it
        belongs to a different payload hash (never removed in that case).
    #>
    param(
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [string] $PayloadHash
    )

    $uri = "{0}(PartitionKey='__RequestId',RowKey='{1}')" -f (Get-StateTableUri), $RequestId

    $existing = $null
    try {
        $response = Invoke-WebRequest -Uri $uri -Method GET -Headers (Get-TableHeaders)
        $existing = [pscustomobject]@{
            Entity = $response.Content | ConvertFrom-Json
            ETag   = [string]$response.Headers.ETag
        }
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $true }
        throw
    }

    if ([string]$existing.Entity.payloadHash -ne $PayloadHash) {
        # A different request (different content) owns this requestId now:
        # never remove someone else's legitimate registration on this caller's
        # behalf.
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($existing.ETag)) {
        throw "requestId index row for '$RequestId' did not include an ETag."
    }

    $headers = Get-TableHeaders
    $headers['If-Match'] = $existing.ETag

    try {
        Invoke-RestMethod -Uri $uri -Method DELETE -Headers $headers | Out-Null
        return $true
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -in @(404, 412)) { return $true }
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
# endregion Inlined functions from: AT.State.psm1

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
