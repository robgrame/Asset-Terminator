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

function ConvertTo-TablePropertyValue {
    param([Parameter(Mandatory)] $Value)

    # Azure Table entities only support scalar property values.
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject] -or $Value -is [array]) {
        return ($Value | ConvertTo-Json -Depth 10 -Compress)
    }
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString('o')
    }
    return $Value
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
        $entity[$key] = ConvertTo-TablePropertyValue -Value $value
    }

    $uri = "{0}(PartitionKey='{1}',RowKey='{2}')" -f (Get-StateTableUri), $Platform, $RequestId
    $headers = Get-TableHeaders
    $headers['Content-Type'] = 'application/json'

    try {
        Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -Body ($entity | ConvertTo-Json -Depth 10) | Out-Null
    }
    catch {
        $serviceError = [string]$_.ErrorDetails.Message
        if (-not [string]::IsNullOrWhiteSpace($serviceError)) {
            throw "Azure Table rejected the state entity: $serviceError"
        }
        throw
    }
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
        $entity[$key] = ConvertTo-TablePropertyValue -Value $value
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
        $entity[$key] = ConvertTo-TablePropertyValue -Value $value
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
# region Inlined functions from: AT.Graph.psm1
# Graph helpers for the dispatch intake Function.
#
# Authentication: OAuth2 *client credentials* using an app registration + client
# secret (GRAPH_TENANT_ID / GRAPH_CLIENT_ID / GRAPH_CLIENT_SECRET). No managed
# identity and no certificate are used. The token is cached in-process until a
# minute before it expires.
#
# Configuration comes from the Function App Application Settings (environment
# variables). Every knob has a safe default so the mock runs with only the three
# GRAPH_* credential settings populated. Configurable settings:
#   GRAPH_TENANT_ID, GRAPH_CLIENT_ID, GRAPH_CLIENT_SECRET   (credentials, required)
#   GRAPH_BASE_URI            (default https://graph.microsoft.com/beta)
#   GRAPH_AUTHORITY_HOST      (default https://login.microsoftonline.com)
#   GRAPH_SCOPE              (default https://graph.microsoft.com/.default)
#   GRAPH_MAX_RETRIES         (default 4)
#   WIPE_KEEP_ENROLLMENT_DATA (default false)
#   WIPE_KEEP_USER_DATA       (default false)


$script:GraphTokenCache = $null   # @{ AccessToken = ...; ExpiresOn = [datetime] }

function Write-MockLog {
    <#
        .SYNOPSIS
            Emits a single-line structured log entry (flows to Application Insights).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('Information', 'Warning', 'Error')][string] $Level = 'Information',
        [hashtable] $Properties
    )

    $correlationId = if ($Properties -and $Properties.ContainsKey('correlationId')) {
        $Properties.correlationId
    }
    else {
        $null
    }

    $payload = [ordered]@{
        timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        level         = $Level
        message       = $Message
        correlationId = $correlationId
    }
    if ($Properties) {
        foreach ($key in $Properties.Keys) { $payload[$key] = $Properties[$key] }
    }

    $line = ($payload | ConvertTo-Json -Compress -Depth 6)
    switch ($Level) {
        'Error'   { Write-Error   $line }
        'Warning' { Write-Warning $line }
        default   { Write-Information $line -InformationAction Continue }
    }
}

function ConvertTo-DeviceOs {
    <#
        .SYNOPSIS
            Normalises the operatingSystem value sent by ServiceNow to one of
            'Windows', 'Mac' or 'Mobile'. Only 'Windows' triggers the Autopilot
            deletion downstream.
        .OUTPUTS
            'Windows' | 'Mac' | 'Mobile' | $null (when unrecognised).
    #>
    [CmdletBinding()]
    param([string] $OperatingSystem)

    if (-not $OperatingSystem) { return $null }
    switch -Regex ($OperatingSystem.Trim().ToLowerInvariant()) {
        '^(windows|win)$'                       { return 'Windows' }
        '^(mac|macos|osx|os x)$'                { return 'Mac' }
        '^(mobile|ios|ipados|android)$'         { return 'Mobile' }
        default                                 { return $null }
    }
}

function Get-GraphToken {
    <#
        .SYNOPSIS
            Returns a Microsoft Graph access token using the app registration +
            client secret (client credentials grant). Cached in-process.
    #>
    [CmdletBinding()]
    param()

    if ($script:GraphTokenCache -and $script:GraphTokenCache.ExpiresOn -gt (Get-Date).AddMinutes(1)) {
        return $script:GraphTokenCache.AccessToken
    }

    $tenantId     = $env:GRAPH_TENANT_ID
    $clientId     = $env:GRAPH_CLIENT_ID
    $clientSecret = $env:GRAPH_CLIENT_SECRET
    if (-not $tenantId -or -not $clientId -or -not $clientSecret) {
        throw 'Graph app-registration settings are missing: set GRAPH_TENANT_ID, GRAPH_CLIENT_ID and GRAPH_CLIENT_SECRET.'
    }

    $body = @{
        client_id     = $clientId
        client_secret = $clientSecret
        scope         = (Get-AppSetting -Name 'GRAPH_SCOPE' -Default 'https://graph.microsoft.com/.default')
        grant_type    = 'client_credentials'
    }

    $authorityHost = (Get-AppSetting -Name 'GRAPH_AUTHORITY_HOST' -Default 'https://login.microsoftonline.com').TrimEnd('/')
    $response = Invoke-RestMethod -Method POST `
        -Uri "$authorityHost/$tenantId/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $body

    $script:GraphTokenCache = @{
        AccessToken = $response.access_token
        ExpiresOn   = (Get-Date).AddSeconds([int]$response.expires_in)
    }
    return $script:GraphTokenCache.AccessToken
}

function Invoke-GraphRequest {
    <#
        .SYNOPSIS
            Resilient Microsoft Graph REST call with retry/backoff on transient errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [object] $Body,
        [int] $MaxRetries = -1
    )

    if ($MaxRetries -lt 0) { $MaxRetries = [int](Get-AppSetting -Name 'GRAPH_MAX_RETRIES' -Default '4') }
    $baseUri = (Get-AppSetting -Name 'GRAPH_BASE_URI' -Default 'https://graph.microsoft.com/beta').TrimEnd('/')
    $uri = if ($Path -match '^https?://') { $Path } else { "$baseUri/$($Path.TrimStart('/'))" }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $headers = @{ Authorization = "Bearer $(Get-GraphToken)"; 'Content-Type' = 'application/json' }
            $params  = @{ Method = $Method; Uri = $uri; Headers = $headers; ErrorAction = 'Stop' }
            if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
                $params.Body = ($Body | ConvertTo-Json -Depth 8)
            }
            return Invoke-RestMethod @params
        }
        catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }

            $isTransient = $status -in @(429, 500, 502, 503, 504)
            if (-not $isTransient -or $attempt -gt $MaxRetries) {
                throw
            }

            $delay = [math]::Min([math]::Pow(2, $attempt), 30)
            Write-MockLog -Level 'Warning' -Message "Graph $Method $uri failed (status $status), retry $attempt/$MaxRetries in ${delay}s"
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-IntuneManagedDevice {
    <#
        .SYNOPSIS
            Resolves an Intune managed device by managedDeviceId, or by deviceName,
            serialNumber and/or imei. When several stale objects match, the freshest
            one (by enrolledDateTime, then lastSyncDateTime) is returned.
        .DESCRIPTION
            A device is reported "not managed" ($null return) ONLY when Graph
            genuinely has no matching object (an empty result set, or a 404 on a
            direct id lookup). Any other Graph failure - authentication, RBAC,
            throttling, a 5xx - is rethrown so the caller can tell "this device is
            not enrolled" apart from "we could not ask Intune right now"; conflating
            the two would route real outages to the manual-task guardrail instead
            of surfacing them as the transient error they are.
        .OUTPUTS
            The managedDevice Graph object, or $null when not found.
    #>
    [CmdletBinding()]
    param(
        [string] $ManagedDeviceId,
        [string] $DeviceName,
        [string] $SerialNumber,
        [string] $Imei,
        [hashtable] $LogProperties = @{}
    )

    $select = 'id,deviceName,operatingSystem,osVersion,isEncrypted,complianceState,enrolledDateTime,lastSyncDateTime,userPrincipalName,serialNumber,manufacturer,imei'

    if ($ManagedDeviceId) {
        try {
            return Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices/$ManagedDeviceId`?`$select=$select"
        }
        catch {
            $status = Get-HttpErrorStatusCode -ErrorRecord $_
            if ($status -eq 404) { return $null }
            throw
        }
    }

    if (-not $DeviceName -and -not $SerialNumber -and -not $Imei) {
        throw 'Get-IntuneManagedDevice requires -ManagedDeviceId, -DeviceName, -SerialNumber or -Imei.'
    }

    $clauses = @()
    if ($DeviceName)   { $clauses += "deviceName eq '$($DeviceName.Replace("'", "''"))'" }
    if ($SerialNumber) { $clauses += "serialNumber eq '$($SerialNumber.Replace("'", "''"))'" }
    if ($Imei)         { $clauses += "imei eq '$($Imei.Replace("'", "''"))'" }
    $filter = [Uri]::EscapeDataString($clauses -join ' and ')

    $candidates = @()
    try {
        $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$filter=$filter&`$select=$select"
        $candidates = @($result.value)
    }
    catch {
        # Some combined $filter clauses (e.g. imei together with deviceName) are
        # rejected by Graph as an unsupported query (400): fall back to a single
        # supported clause and match the remaining criteria client-side. Any
        # other status (401/403/429/5xx) is a real failure and must propagate.
        $status = Get-HttpErrorStatusCode -ErrorRecord $_
        if ($status -ne 400) { throw }

        Write-MockLog -Level 'Warning' -Message "Server-side filter failed (status $status); falling back to client-side matching." -Properties $LogProperties
        if ($DeviceName) {
            $nameFilter = [Uri]::EscapeDataString("deviceName eq '$($DeviceName.Replace("'", "''"))'")
            $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$filter=$nameFilter&`$select=$select"
        }
        elseif ($SerialNumber) {
            $serialFilter = [Uri]::EscapeDataString("serialNumber eq '$($SerialNumber.Replace("'", "''"))'")
            $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$filter=$serialFilter&`$select=$select"
        }
        else {
            $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$select=$select"
        }
        $candidates = @($result.value)
    }

    if ($DeviceName)   { $candidates = @($candidates | Where-Object { $_.deviceName   -eq $DeviceName }) }
    if ($SerialNumber) { $candidates = @($candidates | Where-Object { $_.serialNumber -eq $SerialNumber }) }
    if ($Imei)         { $candidates = @($candidates | Where-Object { $_.imei -eq $Imei }) }

    if ($candidates.Count -eq 0) { return $null }

    if ($candidates.Count -gt 1) {
        Write-MockLog -Level 'Warning' `
            -Message "Found $($candidates.Count) managed devices matching the criteria; selecting the freshest by enrolledDateTime/lastSyncDateTime." `
            -Properties $LogProperties
        $min = [datetime]::MinValue
        return $candidates |
            Sort-Object `
                @{ Expression = { if ($_.enrolledDateTime) { [datetime]$_.enrolledDateTime } else { $min } }; Descending = $true }, `
                @{ Expression = { if ($_.lastSyncDateTime) { [datetime]$_.lastSyncDateTime } else { $min } }; Descending = $true } |
            Select-Object -First 1
    }

    return $candidates[0]
}

function Remove-AutopilotDevice {
    <#
        .SYNOPSIS
            Deletes a device from Windows Autopilot by serial number (Windows only).
        .DESCRIPTION
            Resolves the windowsAutopilotDeviceIdentities object by serialNumber and
            deletes it, so a re-imaged / re-purposed device is no longer bound to the
            tenant's Autopilot profile. Requires DeviceManagementServiceConfig.ReadWrite.All.
        .OUTPUTS
            PSCustomObject: Action, Outcome (DryRun|Deleted|NotFound|Skipped), Detail.
    #>
    [CmdletBinding()]
    param(
        [string] $SerialNumber,
        [switch] $DryRun,
        [hashtable] $LogProperties = @{}
    )

    if (-not $SerialNumber) {
        Write-MockLog -Level 'Warning' -Message 'Autopilot delete skipped: no serialNumber supplied.' -Properties $LogProperties
        return [pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'Skipped'; Detail = 'No serialNumber.' }
    }

    if ($DryRun) {
        Write-MockLog -Level 'Information' -Message "DRY-RUN: Autopilot delete skipped for serial $SerialNumber." -Properties $LogProperties
        return [pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'DryRun'; Detail = "Would delete Autopilot identity for serial $SerialNumber." }
    }

    $escaped = $SerialNumber.Replace("'", "''")
    $filter  = [Uri]::EscapeDataString("contains(serialNumber,'$escaped')")
    $result  = Invoke-GraphRequest -Method GET -Path "deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$filter"
    $identity = @($result.value) | Where-Object { $_.serialNumber -eq $SerialNumber } | Select-Object -First 1
    if (-not $identity) { $identity = @($result.value) | Select-Object -First 1 }

    if (-not $identity) {
        Write-MockLog -Level 'Information' -Message "No Autopilot identity found for serial $SerialNumber; nothing to delete." -Properties $LogProperties
        return [pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'NotFound'; Detail = "No Autopilot identity for serial $SerialNumber." }
    }

    Invoke-GraphRequest -Method DELETE -Path "deviceManagement/windowsAutopilotDeviceIdentities/$($identity.id)" | Out-Null
    Write-MockLog -Level 'Information' -Message "Deleted Autopilot identity $($identity.id) for serial $SerialNumber." -Properties $LogProperties
    return [pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'Deleted'; Detail = "Deleted Autopilot identity $($identity.id)." }
}

function Invoke-IntuneWipe {
    <#
        .SYNOPSIS
            Issues the Intune managedDevice wipe action (or simulates it in DryRun).
        .DESCRIPTION
            POST /deviceManagement/managedDevices/{id}/wipe. Requires
            DeviceManagementManagedDevices.PrivilegedOperations.All.
        .OUTPUTS
            PSCustomObject: Action, Outcome (DryRun|Issued), ExecutedAt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ManagedDeviceId,
        [switch] $DryRun,
        [Nullable[bool]] $KeepEnrollmentData,
        [Nullable[bool]] $KeepUserData,
        [hashtable] $LogProperties = @{}
    )

    if ($null -eq $KeepEnrollmentData) { $KeepEnrollmentData = Get-AppSettingBool -Name 'WIPE_KEEP_ENROLLMENT_DATA' -Default $false }
    if ($null -eq $KeepUserData)       { $KeepUserData       = Get-AppSettingBool -Name 'WIPE_KEEP_USER_DATA' -Default $false }

    if ($DryRun) {
        Write-MockLog -Level 'Information' -Message "DRY-RUN: wipe skipped for managedDevice $ManagedDeviceId." -Properties $LogProperties
        return [pscustomobject]@{ Action = 'Wipe'; Outcome = 'DryRun'; ManagedDeviceId = $ManagedDeviceId; ExecutedAt = (Get-Date).ToUniversalTime().ToString('o') }
    }

    $body = @{ keepEnrollmentData = [bool]$KeepEnrollmentData; keepUserData = [bool]$KeepUserData }
    Invoke-GraphRequest -Method POST -Path "deviceManagement/managedDevices/$ManagedDeviceId/wipe" -Body $body | Out-Null
    Write-MockLog -Level 'Information' -Message "Wipe command issued for managedDevice $ManagedDeviceId." -Properties $LogProperties
    return [pscustomobject]@{ Action = 'Wipe'; Outcome = 'Issued'; ManagedDeviceId = $ManagedDeviceId; ExecutedAt = (Get-Date).ToUniversalTime().ToString('o') }
}

function Get-DeviceWipeStatus {
    <#
        .SYNOPSIS
            Reads the LIVE state of a previously issued Intune wipe for a managed
            device, straight from Microsoft Graph (no local persistence).
        .DESCRIPTION
            GET /deviceManagement/managedDevices/{id} selecting managementState and
            deviceActionResults, then extracts the 'wipe' entry. Intune wipes are
            asynchronous: the command is only carried out when the device next checks
            in, so this reports the real progress after the wipe was issued.

            actionState values (Graph): none | pending | canceled | active | done |
            failed | notSupported | retryPending. 'active' is surfaced as 'inProgress'.
            Requires DeviceManagementManagedDevices.Read.All.
        .OUTPUTS
            PSCustomObject: Found (bool), plus device fields and the wipe action
            result (WipeState, WipeStartDateTime, WipeLastUpdatedDateTime), or
            Found=$false when the managed device no longer exists (already wiped /
            retired objects are removed from Intune).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ManagedDeviceId,
        [datetime] $NotBefore,
        [hashtable] $LogProperties = @{}
    )

    $select = 'id,deviceName,serialNumber,operatingSystem,managementState,lastSyncDateTime'
    $device = $null
    try {
        $device = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices/$ManagedDeviceId`?`$select=$select,deviceActionResults"
    }
    catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 404) {
            Write-MockLog -Level 'Information' -Message "Managed device $ManagedDeviceId not found (likely already wiped/removed)." -Properties $LogProperties
            return [pscustomobject]@{ Found = $false; ManagedDeviceId = $ManagedDeviceId }
        }
        throw
    }

    $wipeActions = @($device.deviceActionResults) | Where-Object { [string]$_.actionName -ieq 'wipe' }
    if ($PSBoundParameters.ContainsKey('NotBefore')) {
        $threshold = $NotBefore.ToUniversalTime().AddMinutes(-2)
        $wipeActions = @($wipeActions | Where-Object {
            $_.startDateTime -and ([datetime]$_.startDateTime).ToUniversalTime() -ge $threshold
        })
    }
    $wipe = $wipeActions |
        Sort-Object @{ Expression = {
            if ($_.lastUpdatedDateTime) { [datetime]$_.lastUpdatedDateTime }
            elseif ($_.startDateTime) { [datetime]$_.startDateTime }
            else { [datetime]::MinValue }
        }; Descending = $true } |
        Select-Object -First 1

    $wipeState = if ($wipe) {
        switch ($wipe.actionState) {
            'active' { 'inProgress' }
            default  { [string]$wipe.actionState }
        }
    }
    else { 'notIssued' }

    return [pscustomobject]@{
        Found                   = $true
        ManagedDeviceId         = $device.id
        DeviceName              = $device.deviceName
        SerialNumber            = $device.serialNumber
        OperatingSystem         = $device.operatingSystem
        ManagementState         = $device.managementState
        LastSyncDateTime        = $device.lastSyncDateTime
        WipeState               = $wipeState
        WipeStartDateTime       = if ($wipe) { $wipe.startDateTime } else { $null }
        WipeLastUpdatedDateTime = if ($wipe) { $wipe.lastUpdatedDateTime } else { $null }
    }
}

function Get-AutopilotDeviceStatus {
    <#
        .SYNOPSIS
            Reports whether a Windows Autopilot identity still exists for a serial
            number (used to confirm the Autopilot deletion took effect).
        .OUTPUTS
            PSCustomObject: Present (bool), AutopilotDeviceId, SerialNumber.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SerialNumber,
        [hashtable] $LogProperties = @{}
    )

    if (-not $SerialNumber) {
        return [pscustomobject]@{ Present = $null; AutopilotDeviceId = $null; SerialNumber = $SerialNumber; Detail = 'No serialNumber to check.' }
    }

    $escaped = $SerialNumber.Replace("'", "''")
    $filter  = [Uri]::EscapeDataString("contains(serialNumber,'$escaped')")
    $result  = Invoke-GraphRequest -Method GET -Path "deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$filter"
    $identity = @($result.value) | Where-Object { $_.serialNumber -eq $SerialNumber } | Select-Object -First 1

    if ($identity) {
        return [pscustomobject]@{ Present = $true; AutopilotDeviceId = $identity.id; SerialNumber = $SerialNumber }
    }
    return [pscustomobject]@{ Present = $false; AutopilotDeviceId = $null; SerialNumber = $SerialNumber }
}
# endregion Inlined functions from: AT.Graph.psm1

function Write-Json {
    param([int] $StatusCode, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = ($Object | ConvertTo-Json -Depth 12)
    })
}

function Get-IntuneWipeView {
    param($Entity)

    $dryRun = Get-JsonPropertyValue -InputObject $Entity -Name 'dryRun'
    if ($dryRun -is [bool] -and $dryRun) { return $null }
    if ([string]$dryRun -match '^(?i:true)$') { return $null }

    $managedDeviceId = [string](Get-JsonPropertyValue -InputObject $Entity -Name 'managedDeviceId')
    if ([string]::IsNullOrWhiteSpace($managedDeviceId)) { return $null }

    $parameters = @{
        ManagedDeviceId = $managedDeviceId
        LogProperties = @{ requestId = $Entity.RowKey; managedDeviceId = $managedDeviceId }
    }
    $notBefore = [datetime]::MinValue
    $dispatchedAt = [string](Get-JsonPropertyValue -InputObject $Entity -Name 'dispatchedAt')
    if ([datetime]::TryParse($dispatchedAt, [ref]$notBefore)) {
        $parameters.NotBefore = $notBefore
    }

    try {
        $wipe = Get-DeviceWipeStatus @parameters
        if (-not $wipe.Found) {
            return [ordered]@{
                found = $false
                managedDeviceId = $managedDeviceId
                wipeState = 'deviceRemoved'
            }
        }
        return [ordered]@{
            found = $true
            managedDeviceId = $wipe.ManagedDeviceId
            deviceName = $wipe.DeviceName
            managementState = $wipe.ManagementState
            lastSyncDateTime = $wipe.LastSyncDateTime
            wipeState = $wipe.WipeState
            startDateTime = $wipe.WipeStartDateTime
            lastUpdatedDateTime = $wipe.WipeLastUpdatedDateTime
        }
    }
    catch {
        Write-AtLog -Level 'Warning' -Message "Unable to query the live Intune wipe state: $($_.Exception.Message)" -Properties $parameters.LogProperties
        return [ordered]@{
            found = $null
            managedDeviceId = $managedDeviceId
            wipeState = 'unavailable'
            error = $_.Exception.Message
        }
    }
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
        intuneWipe        = Get-IntuneWipeView -Entity $Entity
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
