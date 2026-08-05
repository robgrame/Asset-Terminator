#Requires -Version 7.6

# JobMonitor handler - durable reconciliation, run on a timer.
#
# The runbooks take minutes (Windows) to tens of minutes (Apple, which waits for
# the DEP sync to propagate), so nothing in the pipeline blocks on them, and the
# HTTP intake's own dispatch attempt is only best-effort. This timer is what
# actually guarantees forward progress, in three independent passes:
#
#   1. Dispatch reconciliation - claims (ETag-conditional) every request still
#      Accepted or Dispatching whose backoff window has elapsed, and attempts
#      to start (or confirm) its Automation job. Handles crash recovery (a
#      request that was Accepted but never attempted), retries with backoff up
#      to a bounded number of attempts, and the ARM PUT ambiguity (timeout /
#      429 / 5xx) without ever double-starting a job or releasing the device
#      lease on an inconclusive outcome.
#   2. In-flight reconciliation - polls the Automation job status for requests
#      already Dispatched/Running/EvidencePending, and only declares success
#      once a valid '##RESULT##' line has been read back; a terminal job with
#      no usable output yet is retried a bounded number of times before being
#      failed with evidenceState=EvidenceMissing.
#   3. Callback reconciliation - delivers (or retries with backoff) the
#      ServiceNow callback for every request whose callbackStatus is Pending or
#      FailedRetryable, including dry-run completions, using a stable eventId
#      so retried deliveries are idempotent for the receiver.
#
# Every one of these passes claims its row before acting, so a slow HTTP
# request and a JobMonitor tick - or two overlapping ticks - can never step on
# each other.

param($Timer)

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
# region Inlined functions from: AT.Automation.psm1
# Azure Automation runbook dispatch.
#
# Dispatch is always done through ARM:
#   PUT .../automationAccounts/{aa}/jobs/{jobName} with a managed-identity token.
# The client chooses jobName, so replaying the same request never starts a
# duplicate job, and the job status/output can be polled
# deterministically. Webhooks are deliberately not supported: their token lives
# in the URL, they cannot be made idempotent and they return no job status.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


$script:ArmApiVersion = '2023-11-01'

function Get-AutomationAccountResourceId {
    $explicit = Get-AppSetting -Name 'AUTOMATION_ACCOUNT_RESOURCE_ID'
    if (-not [string]::IsNullOrWhiteSpace($explicit)) { return $explicit.TrimEnd('/') }

    $subscription = Get-AppSetting -Name 'AUTOMATION_SUBSCRIPTION_ID' -Required
    $resourceGroup = Get-AppSetting -Name 'AUTOMATION_RESOURCE_GROUP' -Required
    $account = Get-AppSetting -Name 'AUTOMATION_ACCOUNT_NAME' -Required

    return "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Automation/automationAccounts/$account"
}

function Get-ArmHeaders {
    $token = Get-ManagedIdentityToken -Resource 'https://management.azure.com/'
    return @{ 'Authorization' = "Bearer $token" }
}

function Get-RunbookMap {
    $json = Get-AppSetting -Name 'RUNBOOK_MAP' -Required
    return ($json | ConvertFrom-Json)
}

function Resolve-RunbookBinding {
    <#
    .SYNOPSIS
        Resolves the runbook name and the runbook parameters for a message,
        binding '$.a.b' expressions in RUNBOOK_MAP against the message body.
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] $Message
    )

    $map = Get-RunbookMap
    if (-not ($map.PSObject.Properties.Name -contains $Platform)) {
        throw "No runbook configured for platform '$Platform' in RUNBOOK_MAP."
    }

    $entry = $map.$Platform
    $parameters = @{}

    if ($entry.PSObject.Properties.Name -contains 'parameters' -and $entry.parameters) {
        foreach ($property in $entry.parameters.PSObject.Properties) {
            $spec = [string]$property.Value
            # A spec starting with '$.' is a JSON path into the message; anything
            # else is a literal, so constants (KmeRegion, WipeWaitSeconds, ...)
            # can be pinned in configuration without a code change.
            $value = if ($spec.StartsWith('$.')) {
                Resolve-JsonPath -InputObject $Message -Path $spec
            }
            else { $spec }

            if ($null -eq $value -or "$value" -eq '') { continue }
            # Automation runbook parameters are always passed as strings.
            $parameters[$property.Name] = if ($value -is [bool]) { $value.ToString().ToLowerInvariant() } else { "$value" }
        }
    }

    $timeout = 30
    if ($entry.PSObject.Properties.Name -contains 'timeoutMinutes' -and $entry.timeoutMinutes) {
        $timeout = [int]$entry.timeoutMinutes
    }

    return [pscustomobject]@{
        Runbook        = [string]$entry.runbook
        Parameters     = $parameters
        TimeoutMinutes = $timeout
        RunOn          = if ($entry.PSObject.Properties.Name -contains 'runOn') { [string]$entry.runOn } else { '' }
    }
}

function Start-AutomationRunbookJob {
    <#
    .SYNOPSIS
        Starts a runbook job with a caller-supplied job name (idempotent).
    .OUTPUTS
        PSCustomObject with JobName, JobId and Status.
    #>
    param(
        [Parameter(Mandatory)] [string] $JobName,
        [Parameter(Mandatory)] [string] $Runbook,
        [hashtable] $Parameters,
        [string] $RunOn = ''
    )

    $uri = '{0}/jobs/{1}?api-version={2}' -f (Get-AutomationAccountResourceId), $JobName, $script:ArmApiVersion

    $properties = @{
        runbook = @{ name = $Runbook }
        runOn   = $RunOn
    }
    if ($Parameters -and $Parameters.Count -gt 0) { $properties['parameters'] = $Parameters }

    $body = @{ properties = $properties } | ConvertTo-Json -Depth 8

    $response = Invoke-RestMethod -Uri "https://management.azure.com$uri" -Method PUT `
        -Headers (Get-ArmHeaders) -ContentType 'application/json' -Body $body

    return [pscustomobject]@{
        JobName = $JobName
        JobId   = $response.properties.jobId
        Status  = $response.properties.status
    }
}

function Get-AutomationRunbookJob {
    param([Parameter(Mandatory)] [string] $JobName)

    $uri = '{0}/jobs/{1}?api-version={2}' -f (Get-AutomationAccountResourceId), $JobName, $script:ArmApiVersion

    try {
        $response = Invoke-RestMethod -Uri "https://management.azure.com$uri" -Method GET -Headers (Get-ArmHeaders)
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }

    return [pscustomobject]@{
        JobName       = $JobName
        JobId         = $response.properties.jobId
        Status        = $response.properties.status
        StatusDetails = $response.properties.statusDetails
        StartTime     = $response.properties.startTime
        EndTime       = $response.properties.endTime
        Exception     = $response.properties.exception
    }
}

function Get-AutomationRunbookJobOutput {
    param([Parameter(Mandatory)] [string] $JobName)

    $uri = '{0}/jobs/{1}/output?api-version={2}' -f (Get-AutomationAccountResourceId), $JobName, $script:ArmApiVersion

    try {
        return Invoke-RestMethod -Uri "https://management.azure.com$uri" -Method GET -Headers (Get-ArmHeaders)
    }
    catch {
        return $null
    }
}

# Terminal Automation job states.
function Test-AutomationJobTerminal {
    param([string] $Status)
    return $Status -in @('Completed', 'Failed', 'Stopped', 'Suspended')
}

function Test-TransientArmStatusCode {
    <#
    .SYNOPSIS
        True for the status codes where ARM's outcome is genuinely ambiguous:
        a timeout or 5xx can mean "the request never reached the service" or
        "it succeeded but the response was lost"; 429 means the request may or
        may not have been throttled before or after taking effect.
    #>
    param([Nullable[int]] $StatusCode)

    if ($null -eq $StatusCode) { return $true } # no response at all: network/timeout
    return $StatusCode -eq 429 -or $StatusCode -ge 500
}

function Get-ArmErrorStatusCode {
    param($ErrorRecord)
    return Get-HttpErrorStatusCode -ErrorRecord $ErrorRecord
}

function Invoke-IdempotentRunbookDispatch {
    <#
    .SYNOPSIS
        Starts a runbook job through ARM with a deterministic job name, without
        ever risking a duplicate job when the PUT's outcome is ambiguous.
    .DESCRIPTION
        ARM PUT .../jobs/{jobName} is idempotent *if it reaches the service*,
        but a client-side timeout, a 429 or a 5xx leaves the true outcome
        unknown: the job may have started anyway. The dispatcher must never
        guess in that situation, because guessing wrong either starts a
        duplicate wipe or reports failure for a job that is actually running.

        Sequence:
          1. GET the job first. If it already exists, the PUT is unnecessary
             (a previous attempt succeeded, or is genuinely known now).
          2. Otherwise PUT. A clean success or a clean permanent failure (4xx
             other than 429) is unambiguous.
          3. On a transient failure (timeout / 429 / 5xx) GET the job again:
             - found  -> the PUT actually took effect: Confirmed/Started.
             - 404    -> confirmed absent: safe for the *next* attempt to PUT
               again; this attempt reports Outcome='ConfirmedAbsent' (not a
               permanent failure) so the caller can retry with backoff.
             - the confirming GET itself fails -> Outcome='Unknown': the
               caller must not retry the PUT this attempt (that could create a
               duplicate job) and must not treat this as a terminal failure or
               release any lease; it simply tries again later.
    .OUTPUTS
        PSCustomObject: Outcome ('Started'|'ConfirmedAbsent'|'Unknown'|'PermanentFailure'),
        Job (the job object when known), ErrorMessage.
    #>
    param(
        [Parameter(Mandatory)] [string] $JobName,
        [Parameter(Mandatory)] [string] $Runbook,
        [hashtable] $Parameters,
        [string] $RunOn = ''
    )

    # Step 1: a job with this deterministic name may already exist from a prior
    # attempt whose PUT response never reached us.
    try {
        $existing = Get-AutomationRunbookJob -JobName $JobName
        if ($existing) {
            return [pscustomobject]@{ Outcome = 'Started'; Job = $existing; ErrorMessage = '' }
        }
    }
    catch {
        # The pre-check itself is best-effort: fall through to the PUT. If the
        # PUT also fails ambiguously, the post-check below still applies.
        Write-Warning "Pre-dispatch job lookup failed for '$JobName': $($_.Exception.Message)"
    }

    try {
        $job = Start-AutomationRunbookJob -JobName $JobName -Runbook $Runbook -Parameters $Parameters -RunOn $RunOn
        return [pscustomobject]@{ Outcome = 'Started'; Job = $job; ErrorMessage = '' }
    }
    catch {
        $statusCode = Get-ArmErrorStatusCode -ErrorRecord $_
        if (-not (Test-TransientArmStatusCode -StatusCode $statusCode)) {
            # A clean permanent failure (bad runbook name, RBAC denied, malformed
            # parameters, ...): retrying the same PUT would only fail again.
            return [pscustomobject]@{ Outcome = 'PermanentFailure'; Job = $null; ErrorMessage = $_.Exception.Message }
        }

        $putError = $_.Exception.Message
        try {
            $confirmed = Get-AutomationRunbookJob -JobName $JobName
        }
        catch {
            # The confirming GET is itself unreliable right now: the outcome of
            # the PUT genuinely cannot be determined this attempt.
            return [pscustomobject]@{
                Outcome      = 'Unknown'
                Job          = $null
                ErrorMessage = "PUT failed ambiguously ($putError) and the confirming GET also failed: $($_.Exception.Message)"
            }
        }

        if ($confirmed) {
            return [pscustomobject]@{ Outcome = 'Started'; Job = $confirmed; ErrorMessage = '' }
        }

        # GET confirms the job does not exist: it is safe to PUT again next time.
        return [pscustomobject]@{
            Outcome      = 'ConfirmedAbsent'
            Job          = $null
            ErrorMessage = "PUT failed ambiguously (status $statusCode): $putError. A follow-up GET confirmed the job was not created; safe to retry."
        }
    }
}

function ConvertFrom-RunbookOutput {
    <#
    .SYNOPSIS
        Extracts the structured result a runbook emits as a '##RESULT## {json}'
        line. Falls back to $null when the runbook produced no marker line yet,
        or when the marker line is not valid JSON.
    #>
    param([string] $Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return $null }

    $line = ($Output -split "`n") |
        Where-Object { $_ -match '##RESULT##' } |
        Select-Object -Last 1

    if (-not $line) { return $null }

    $json = $line.Substring($line.IndexOf('##RESULT##') + 10).Trim()
    try { return $json | ConvertFrom-Json } catch { return $null }
}

function Get-RunbookOutputEvidenceState {
    <#
    .SYNOPSIS
        Classifies why a terminal, 'Completed' Automation job produced no
        parsed result, so JobMonitor can distinguish a transient evidence gap
        (worth a retry) from a runbook that will never emit one.
    .DESCRIPTION
        A completed job with no output at all is most often the Automation
        output store lagging behind the job status: retry a bounded number of
        times ('EvidencePending'). A completed job whose output *is* present
        but has no '##RESULT##' line, or an invalid one, means the runbook
        itself never produced the contract it promises: that is not something
        a retry will fix ('EvidenceMissing'), but it is still recorded as
        retryable-once in case the output store is only briefly behind the job
        status transition.
    .OUTPUTS
        'HasResult' | 'EvidencePending' | 'EvidenceMissing'
    #>
    param(
        [string] $Output,
        $ParsedResult
    )

    if ($null -ne $ParsedResult) { return 'HasResult' }
    if ([string]::IsNullOrWhiteSpace($Output)) { return 'EvidencePending' }
    return 'EvidenceMissing'
}
# endregion Inlined functions from: AT.Automation.psm1
# region Inlined functions from: AT.Dispatch.psm1
# Translates one canonical intake payload into one Automation runbook job, and
# provides the durable claim/retry primitives JobMonitor uses to reconcile any
# request that did not finish dispatching inline (crash recovery, ambiguous
# ARM responses, throttling, ...).
#
# Design summary (see docs/flusso-alto-livello.md for the full narrative):
#   - WipeIntake persists the full canonical payload with status=Accepted
#     *before* attempting anything (durable handoff / write-before-action).
#     The immediate dispatch attempt that follows is an optimisation, not a
#     requirement for correctness: if it does not happen, or does not finish,
#     JobMonitor will.
#   - Every dispatch attempt - whether inline from WipeIntake or reconciled by
#     JobMonitor - first claims the row with an ETag-conditional MERGE, so two
#     workers can never both start the same runbook job.
#   - A deterministic job name (the requestId) makes the ARM PUT itself
#     idempotent; Invoke-IdempotentRunbookDispatch (AT.Automation) adds the
#     GET-before/GET-after checks that keep a timeout/429/5xx from ever being
#     misread as a clean failure or a clean success.
#   - Attempts are bounded: after DISPATCH_MAX_ATTEMPTS the request is failed
#     terminally (DispatchFailed) instead of retrying forever.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function Get-DispatchMaxAttempts {
    return Get-AppSettingInt -Name 'DISPATCH_MAX_ATTEMPTS' -Default 8
}

function Get-DispatchBackoffBaseSeconds {
    return Get-AppSettingInt -Name 'DISPATCH_BACKOFF_BASE_SECONDS' -Default 20
}

function Get-DispatchBackoffMaxSeconds {
    return Get-AppSettingInt -Name 'DISPATCH_BACKOFF_MAX_SECONDS' -Default 1800
}

function Get-DispatchMaxConcurrency {
    return Get-AppSettingInt -Name 'DISPATCH_MAX_CONCURRENCY' -Default 10
}

function Get-EvidenceMaxAttempts {
    return Get-AppSettingInt -Name 'EVIDENCE_MAX_ATTEMPTS' -Default 5
}

function Get-CallbackMaxAttempts {
    return Get-AppSettingInt -Name 'CALLBACK_MAX_ATTEMPTS' -Default 6
}

function Get-CallbackBackoffBaseSeconds {
    return Get-AppSettingInt -Name 'CALLBACK_BACKOFF_BASE_SECONDS' -Default 15
}

function Get-CallbackBackoffMaxSeconds {
    return Get-AppSettingInt -Name 'CALLBACK_BACKOFF_MAX_SECONDS' -Default 900
}

function Get-CallbackMaxConcurrency {
    return Get-AppSettingInt -Name 'CALLBACK_MAX_CONCURRENCY' -Default 20
}

function Set-CallbackPending {
    <#
    .SYNOPSIS
        Arms the durable callback pipeline for a request that just reached a
        terminal state (Completed, PartiallyCompleted, Failed or DispatchFailed
        - dry runs included). Does nothing when the request has no callbackUrl.
    .DESCRIPTION
        Sets callbackStatus='Pending' and assigns a stable eventId the first
        time a terminal state is reached, so every callback delivery attempt
        for this outcome - however many retries it takes - carries the same
        requestId/eventId pair for the receiver's own idempotency check.
    .OUTPUTS
        The eventId used, or $null when no callback is configured.
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestId,
        [string] $CallbackUrl,
        [string] $ExistingEventId
    )

    if ([string]::IsNullOrWhiteSpace($CallbackUrl)) { return $null }

    $eventId = if ([string]::IsNullOrWhiteSpace($ExistingEventId)) { [guid]::NewGuid().ToString() } else { $ExistingEventId }

    Update-WipeRequestState -Platform $Platform -RequestId $RequestId -Properties @{
        callbackStatus   = 'Pending'
        callbackAttempts = 0
        eventId          = $eventId
    }

    return $eventId
}

# ---------------------------------------------------------------------------
# Reconciliation candidate discovery (JobMonitor's dispatch pass)
# ---------------------------------------------------------------------------
function Get-DispatchCandidateRequests {
    <#
    .SYNOPSIS
        Requests still waiting for a durable dispatch outcome: freshly accepted
        (never attempted) or mid-retry after a prior ambiguous/transient
        failure. Ordering/limiting to a bounded concurrency happens in
        Get-DueDispatchCandidates so one JobMonitor tick never tries to claim
        an unbounded number of rows.
    #>
    param([int] $Top = 200)
    return @(Find-WipeRequestState -Filter "status eq 'Accepted' or status eq 'Dispatching'" -Top $Top)
}

function Test-BackoffFieldDue {
    <#
    .SYNOPSIS
        Generic backoff check shared by the dispatch and callback reconciliation
        passes: true when the named datetime field is absent, unparsable, or in
        the past.
    #>
    param($Request, [Parameter(Mandatory)] [string] $FieldName)

    $hasField = $Request.PSObject.Properties.Name -contains $FieldName -and $Request.$FieldName
    if (-not $hasField) { return $true }

    $next = $null
    if (-not [datetime]::TryParse([string]$Request.$FieldName, [ref] $next)) { return $true }
    return (Get-Date).ToUniversalTime() -ge $next.ToUniversalTime()
}

function Test-DispatchAttemptDue {
    <#
    .SYNOPSIS
        True when a candidate request has no scheduled backoff yet, or its
        backoff window has elapsed.
    #>
    param($Request)
    return Test-BackoffFieldDue -Request $Request -FieldName 'nextAttemptAt'
}

function Get-DueDispatchCandidates {
    <#
    .SYNOPSIS
        Candidate requests whose backoff window has elapsed, capped at the
        configured dispatch concurrency limit so a single JobMonitor tick
        cannot overwhelm the Automation account with simultaneous ARM PUTs.
    #>
    param([int] $MaxConcurrency = -1)

    if ($MaxConcurrency -lt 0) { $MaxConcurrency = Get-DispatchMaxConcurrency }
    $candidates = @(Get-DispatchCandidateRequests | Where-Object { Test-DispatchAttemptDue -Request $_ })
    return @($candidates | Select-Object -First $MaxConcurrency)
}

# ---------------------------------------------------------------------------
# Atomic claim
# ---------------------------------------------------------------------------
function Invoke-DispatchClaim {
    <#
    .SYNOPSIS
        Atomically claims one request row for a dispatch attempt using an
        ETag-conditional MERGE. Two callers racing for the same row (a second
        JobMonitor tick, or JobMonitor racing WipeIntake's own inline attempt)
        can never both win: the loser's MERGE is rejected with HTTP 412 and it
        simply moves on to the next candidate.
    .OUTPUTS
        PSCustomObject: Claimed (bool), Reason, Entity (the pre-claim entity).
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestId
    )

    $current = Get-WipeRequestStateWithETag -Platform $Platform -RequestId $RequestId
    if (-not $current) {
        return [pscustomobject]@{ Claimed = $false; Reason = 'NotFound'; Entity = $null }
    }
    if ([string]$current.Entity.status -notin @('Accepted', 'Dispatching')) {
        return [pscustomobject]@{ Claimed = $false; Reason = 'NotEligible'; Entity = $current.Entity }
    }

    $claimed = Set-WipeRequestStateClaim -Platform $Platform -RequestId $RequestId -ETag $current.ETag -Properties @{
        status        = 'Dispatching'
        claimedAt     = (Get-Date).ToUniversalTime()
        lastAttemptAt = (Get-Date).ToUniversalTime()
    }

    if (-not $claimed) {
        return [pscustomobject]@{ Claimed = $false; Reason = 'ClaimConflict'; Entity = $current.Entity }
    }

    return [pscustomobject]@{ Claimed = $true; Reason = ''; Entity = $current.Entity }
}

function ConvertTo-DispatchMessage {
    <#
    .SYNOPSIS
        Rebuilds the canonical dispatch payload from a durably persisted state
        row (the 'payloadJson' property written by WipeIntake at Accepted
        time). This is what lets JobMonitor redispatch a request after a
        Function App restart without ever holding the original HTTP payload
        in memory.
    #>
    param($Entity)

    $payloadJson = Get-JsonPropertyValue -InputObject $Entity -Name 'payloadJson'
    if ([string]::IsNullOrWhiteSpace([string]$payloadJson)) {
        throw "Request row for '$($Entity.RowKey)' has no persisted payloadJson; cannot reconstruct the dispatch message."
    }
    return ([string]$payloadJson | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Dispatch attempt (used both by WipeIntake's optional immediate attempt and
# by JobMonitor's reconciliation pass, always AFTER Invoke-DispatchClaim)
# ---------------------------------------------------------------------------
function Invoke-DisposalDispatch {
    <#
    .SYNOPSIS
        Performs one dispatch attempt for an already-claimed request: resolves
        the runbook binding, calls ARM through the ambiguity-safe helper, and
        persists the outcome. Never throws for a dispatch-side failure: every
        outcome (Dispatched, retryable Dispatching-with-backoff, or terminal
        DispatchFailed once attempts are exhausted) is returned and persisted.
    .OUTPUTS
        PSCustomObject: Status ('Completed'|'Dispatched'|'Dispatching'|'DispatchFailed'),
        ErrorMessage, AutomationJobName, AutomationJobId, Attempt, Terminal (bool),
        ReleaseLease (bool - true once the request reaches ANY terminal state).
    #>
    param(
        [Parameter(Mandatory)] $Message,
        [Parameter(Mandatory)] [string] $ExpectedPlatform,
        [int] $Attempt = 1,
        [int] $MaxAttempts = -1
    )

    if ($MaxAttempts -lt 0) { $MaxAttempts = Get-DispatchMaxAttempts }

    $payload = ConvertFrom-JsonBody -Body $Message
    if (-not $payload) { throw 'Dispatch payload body is not valid JSON.' }

    $requestId = [string]$payload.requestId
    $platform = [string]$payload.platform

    if ([string]::IsNullOrWhiteSpace($requestId)) { throw 'Message is missing requestId.' }
    if ($platform -ne $ExpectedPlatform) {
        throw "Message platform '$platform' does not match the expected platform '$ExpectedPlatform'."
    }

    $dryRunValue = Resolve-JsonPath -InputObject $payload -Path '$.options.dryRun'
    if ($null -eq $dryRunValue) { throw 'Message is missing options.dryRun.' }
    try {
        # Never cast a string directly to [bool]: in PowerShell [bool]'false' is
        # true because every non-empty string is truthy.
        $isDryRun = [System.Convert]::ToBoolean($dryRunValue)
    }
    catch {
        throw "Message options.dryRun must be a boolean, received '$dryRunValue'."
    }

    $callbackUrl = [string](Get-JsonPropertyValue -InputObject $payload -Name 'callbackUrl')

    $logProps = @{
        requestId     = $requestId
        correlationId = [string]$payload.correlationId
        platform      = $platform
        scenario      = [string]$payload.scenario
        serialNumber  = [string]$payload.device.serialNumber
        dryRun        = $isDryRun
        attempt       = $Attempt
    }

    Write-AtLog -Level 'Information' -Message 'Dispatching disposal request.' -Properties $logProps
    Write-AtAudit -Action 'WipeDispatchStarted' -Properties $logProps

    # Retirement never removes the device from its enrollment platform. Until the
    # runbooks accept a -Scenario parameter, a retirement request must not be sent
    # to a runbook whose first action is the unenrollment. This is a static
    # configuration problem: retrying will never fix it, so it fails terminally
    # on the first attempt rather than consuming the retry budget.
    if (-not [bool]$payload.options.removeFromEnrollmentPlatform -and
        -not (Get-AppSettingBool -Name 'RUNBOOKS_SUPPORT_SCENARIO' -Default $false)) {
        $reason = 'Retirement scenario requires runbooks that support -Scenario; set RUNBOOKS_SUPPORT_SCENARIO=true once updated.'
        Write-AtLog -Level 'Warning' -Message $reason -Properties $logProps
        Write-AtAudit -Action 'WipeDispatchFailed' -Level 'Error' -Properties ($logProps + @{ status = 'DispatchFailed'; error = $reason })
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'DispatchFailed'; errorMessage = $reason; completedAt = (Get-Date).ToUniversalTime(); attempts = $Attempt
        }
        Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl ($callbackUrl) | Out-Null
        return [pscustomobject]@{
            Status = 'DispatchFailed'; ErrorMessage = $reason; AutomationJobName = $null; AutomationJobId = $null
            Attempt = $Attempt; Terminal = $true; ReleaseLease = $true
        }
    }

    try {
        $binding = Resolve-RunbookBinding -Platform $platform -Message $payload
    }
    catch {
        # A misconfigured RUNBOOK_MAP is also a static problem: fail terminally.
        $reason = "Unable to resolve the runbook binding: $($_.Exception.Message)"
        Write-AtLog -Level 'Error' -Message $reason -Properties $logProps
        Write-AtAudit -Action 'WipeDispatchFailed' -Level 'Error' -Properties ($logProps + @{ status = 'DispatchFailed'; error = $reason })
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'DispatchFailed'; errorMessage = $reason; completedAt = (Get-Date).ToUniversalTime(); attempts = $Attempt
        }
        Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl ($callbackUrl) | Out-Null
        return [pscustomobject]@{
            Status = 'DispatchFailed'; ErrorMessage = $reason; AutomationJobName = $null; AutomationJobId = $null
            Attempt = $Attempt; Terminal = $true; ReleaseLease = $true
        }
    }

    # Idempotent job name: replaying the message returns the existing job.
    $jobName = $requestId

    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        status            = 'Dispatching'
        runbook           = $binding.Runbook
        timeoutMinutes    = $binding.TimeoutMinutes
        automationJobName = $jobName
        attempts          = $Attempt
        lastAttemptAt     = (Get-Date).ToUniversalTime()
    }

    if ($isDryRun) {
        Write-AtLog -Level 'Information' -Message 'Dry run: runbook not started.' -Properties $logProps
        Write-AtAudit -Action 'WipeDryRunCompleted' -Properties ($logProps + @{ status = 'Completed'; runbook = $binding.Runbook })
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'Completed'
            completedAt = (Get-Date).ToUniversalTime()
            resultJson = @{ dryRun = $true; runbook = $binding.Runbook; parameters = $binding.Parameters }
        }
        Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl ($callbackUrl) | Out-Null
        return [pscustomobject]@{
            Status = 'Completed'; ErrorMessage = ''; AutomationJobName = $null; AutomationJobId = $null
            Attempt = $Attempt; Terminal = $true; ReleaseLease = $true
        }
    }

    $dispatch = Invoke-IdempotentRunbookDispatch -JobName $jobName -Runbook $binding.Runbook `
        -Parameters $binding.Parameters -RunOn $binding.RunOn

    if ($dispatch.Outcome -eq 'Started') {
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status            = 'Dispatched'
            automationJobName = [string]$dispatch.Job.JobName
            automationJobId   = [string]$dispatch.Job.JobId
            dispatchedAt      = (Get-Date).ToUniversalTime()
            errorMessage      = ''
            dispatchOutcome   = 'Started'
        }
        $logProps.automationJobName = [string]$dispatch.Job.JobName
        Write-AtLog -Level 'Information' -Message 'Runbook job started.' -Properties $logProps
        Write-AtAudit -Action 'WipeJobStarted' -Properties ($logProps + @{ status = 'Dispatched'; runbook = $binding.Runbook; automationJobId = [string]$dispatch.Job.JobId })

        return [pscustomobject]@{
            Status = 'Dispatched'; ErrorMessage = ''
            AutomationJobName = [string]$dispatch.Job.JobName; AutomationJobId = [string]$dispatch.Job.JobId
            Attempt = $Attempt; Terminal = $false; ReleaseLease = $false
        }
    }

    # Outcome is PermanentFailure, ConfirmedAbsent or Unknown: never mark the
    # request DispatchFailed - and never release the device lease - while
    # attempts remain. 'Unknown' in particular must not be retried blindly
    # (the previous PUT might still land); the next attempt starts, as always,
    # with a fresh GET, so it self-corrects once ARM's state settles.
    $exhausted = $Attempt -ge $MaxAttempts

    if (-not $exhausted) {
        $delay = Get-BackoffDelaySeconds -Attempt $Attempt -BaseSeconds (Get-DispatchBackoffBaseSeconds) -MaxSeconds (Get-DispatchBackoffMaxSeconds)
        $nextAttemptAt = (Get-Date).ToUniversalTime().AddSeconds($delay)

        Write-AtLog -Level 'Warning' -Message "Dispatch attempt $Attempt/$MaxAttempts inconclusive ($($dispatch.Outcome)): $($dispatch.ErrorMessage). Retrying at $($nextAttemptAt.ToString('o'))." -Properties $logProps
        Write-AtAudit -Action 'WipeDispatchRetryScheduled' -Level 'Warning' -Properties ($logProps + @{ status = 'Dispatching'; dispatchOutcome = $dispatch.Outcome; nextAttemptAt = $nextAttemptAt.ToString('o') })

        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status          = 'Dispatching'
            errorMessage    = $dispatch.ErrorMessage
            dispatchOutcome = $dispatch.Outcome
            nextAttemptAt   = $nextAttemptAt
        }

        return [pscustomobject]@{
            Status = 'Dispatching'; ErrorMessage = $dispatch.ErrorMessage
            AutomationJobName = $jobName; AutomationJobId = $null
            Attempt = $Attempt; Terminal = $false; ReleaseLease = $false
        }
    }

    $terminalReason = if ($dispatch.Outcome -eq 'Unknown') {
        "Dispatch outcome could not be confirmed after $Attempt attempts (last: $($dispatch.ErrorMessage)). Manual verification of Automation job '$jobName' is required before assuming the device was not actioned."
    }
    else {
        "Dispatch failed after $Attempt attempts ($($dispatch.Outcome)): $($dispatch.ErrorMessage)"
    }

    Write-AtLog -Level 'Error' -Message $terminalReason -Properties $logProps
    Write-AtAudit -Action 'WipeDispatchFailed' -Level 'Error' -Properties ($logProps + @{ status = 'DispatchFailed'; dispatchOutcome = $dispatch.Outcome; error = $terminalReason })

    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        status          = 'DispatchFailed'
        errorMessage     = $terminalReason
        dispatchOutcome  = $dispatch.Outcome
        completedAt      = (Get-Date).ToUniversalTime()
        attempts         = $Attempt
    }
    Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl ($callbackUrl) | Out-Null

    return [pscustomobject]@{
        Status = 'DispatchFailed'; ErrorMessage = $terminalReason
        AutomationJobName = $jobName; AutomationJobId = $null
        Attempt = $Attempt; Terminal = $true; ReleaseLease = $true
    }
}

function Invoke-DispatchReconciliation {
    <#
    .SYNOPSIS
        End-to-end reconciliation of one candidate request row for JobMonitor:
        claim -> rebuild the canonical message from the durable payload ->
        attempt dispatch. Skips the row cleanly (Claimed=$false) when another
        worker already owns it.
    #>
    param([Parameter(Mandatory)] $Request)

    $platform = [string]$Request.PartitionKey
    $requestId = [string]$Request.RowKey

    $claim = Invoke-DispatchClaim -Platform $platform -RequestId $requestId
    if (-not $claim.Claimed) {
        return [pscustomobject]@{ Claimed = $false; Reason = $claim.Reason; Result = $null }
    }

    $priorAttempts = 0
    if ($claim.Entity.PSObject.Properties.Name -contains 'attempts' -and $claim.Entity.attempts) {
        [int]::TryParse([string]$claim.Entity.attempts, [ref] $priorAttempts) | Out-Null
    }
    $attempt = $priorAttempts + 1

    try {
        $message = ConvertTo-DispatchMessage -Entity $claim.Entity
    }
    catch {
        Write-AtLog -Level 'Error' -Message "JobMonitor: cannot reconcile dispatch for '$requestId': $($_.Exception.Message)" -Properties @{ requestId = $requestId; platform = $platform }
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'DispatchFailed'; errorMessage = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime()
        }
        return [pscustomobject]@{
            Claimed = $true; Reason = ''
            Result  = [pscustomobject]@{ Status = 'DispatchFailed'; ErrorMessage = $_.Exception.Message; Terminal = $true; ReleaseLease = $true }
        }
    }

    $result = Invoke-DisposalDispatch -Message $message -ExpectedPlatform $platform -Attempt $attempt
    return [pscustomobject]@{ Claimed = $true; Reason = ''; Result = $result }
}

# ---------------------------------------------------------------------------
# In-flight reconciliation: polls Automation for requests whose runbook job is
# already known (Dispatched/Running), and for requests waiting on the job's
# output to catch up with its already-terminal status (EvidencePending).
# ---------------------------------------------------------------------------
function Get-InFlightCandidateRequests {
    param([int] $Top = 200)
    return @(Find-WipeRequestState -Filter "status eq 'Dispatched' or status eq 'Running' or status eq 'EvidencePending'" -Top $Top)
}

function Resolve-RequestTerminalStatus {
    <#
    .SYNOPSIS
        Maps a completed Automation job's parsed ##RESULT## onto the request
        state machine. A runbook that completes with per-device errors is
        PartiallyCompleted, not Completed: the process must be able to tell
        "unenrolled but not wiped" from full success.
    #>
    param([string] $JobStatus, $Result)

    if ($JobStatus -ne 'Completed') { return 'Failed' }
    if ($null -eq $Result) { return 'Completed' }

    $hasErrors = $false
    if ($Result.PSObject.Properties.Name -contains 'errors' -and $Result.errors) {
        $hasErrors = @($Result.errors).Count -gt 0
    }

    $wipeIssued = $true
    if ($Result.PSObject.Properties.Name -contains 'wipeIssued') { $wipeIssued = [bool]$Result.wipeIssued }

    if (-not $wipeIssued) { return 'Failed' }
    if ($hasErrors) { return 'PartiallyCompleted' }
    return 'Completed'
}

function Invoke-InFlightReconciliation {
    <#
    .SYNOPSIS
        Reconciles one request whose Automation job is already known: polls
        the job status, and once terminal, requires a valid '##RESULT##' line
        before declaring success. A terminal job with no usable evidence yet
        is retried a bounded number of times as 'EvidencePending'; running out
        of those retries - or the overall per-platform timeout - fails the
        request with evidenceState='EvidenceMissing'.
    .OUTPUTS
        PSCustomObject: Status, EvidenceState, ReleaseLease (bool),
        CallbackEventId (string or $null), Handled (bool - $false when the
        request is still legitimately in progress and nothing changed).
    #>
    param([Parameter(Mandatory)] $Request)

    $platform = [string]$Request.PartitionKey
    $requestId = [string]$Request.RowKey
    $callbackUrl = [string](Get-JsonPropertyValue -InputObject $Request -Name 'callbackUrl')
    $existingEventId = [string](Get-JsonPropertyValue -InputObject $Request -Name 'eventId')

    $logProps = @{
        requestId     = $requestId
        platform      = $platform
        correlationId = Get-JsonPropertyValue -InputObject $Request -Name 'correlationId'
        serialNumber  = Get-JsonPropertyValue -InputObject $Request -Name 'serialNumber'
    }

    $jobName = [string](Get-JsonPropertyValue -InputObject $Request -Name 'automationJobName')
    if ([string]::IsNullOrWhiteSpace($jobName)) {
        Write-AtLog -Level 'Warning' -Message 'JobMonitor: no Automation job name recorded, skipping.' -Properties $logProps
        return [pscustomobject]@{ Status = $Request.status; EvidenceState = $null; ReleaseLease = $false; CallbackEventId = $null; Handled = $false }
    }

    $timeoutMinutes = 60
    $timeoutValue = Get-JsonPropertyValue -InputObject $Request -Name 'timeoutMinutes'
    if ($timeoutValue) { $timeoutMinutes = [int]$timeoutValue }

    $dispatchedAt = $null
    $dispatchedAtValue = Get-JsonPropertyValue -InputObject $Request -Name 'dispatchedAt'
    if ($dispatchedAtValue) { try { $dispatchedAt = [datetime]::Parse($dispatchedAtValue).ToUniversalTime() } catch { $dispatchedAt = $null } }
    $expired = $dispatchedAt -and ((Get-Date).ToUniversalTime() -gt $dispatchedAt.AddMinutes($timeoutMinutes))

    try {
        $job = Get-AutomationRunbookJob -JobName $jobName
    }
    catch {
        Write-AtLog -Level 'Error' -Message "JobMonitor: job lookup failed: $($_.Exception.Message)" -Properties $logProps
        return [pscustomobject]@{ Status = $Request.status; EvidenceState = $null; ReleaseLease = $false; CallbackEventId = $null; Handled = $false }
    }

    if (-not $job) {
        if ($expired) {
            Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
                status = 'Failed'; errorMessage = 'Automation job not found and request timed out.'
                evidenceState = 'EvidenceMissing'; completedAt = (Get-Date).ToUniversalTime()
            }
            $eventId = Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl $callbackUrl -ExistingEventId $existingEventId
            return [pscustomobject]@{ Status = 'Failed'; EvidenceState = 'EvidenceMissing'; ReleaseLease = $true; CallbackEventId = $eventId; Handled = $true }
        }
        return [pscustomobject]@{ Status = $Request.status; EvidenceState = $null; ReleaseLease = $false; CallbackEventId = $null; Handled = $false }
    }

    if (-not (Test-AutomationJobTerminal -Status $job.Status)) {
        if ($expired) {
            Write-AtLog -Level 'Warning' -Message "JobMonitor: request timed out after $timeoutMinutes minutes." -Properties $logProps
            Write-AtAudit -Action 'WipeTimeout' -Level 'Warning' -Properties ($logProps + @{ status = 'Failed'; timeoutMinutes = $timeoutMinutes; lastJobStatus = [string]$job.Status })
            Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
                status = 'Failed'; errorMessage = "Runbook job timeout after $timeoutMinutes minutes (last status: $($job.Status))."
                evidenceState = 'EvidenceMissing'; completedAt = (Get-Date).ToUniversalTime()
            }
            $eventId = Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl $callbackUrl -ExistingEventId $existingEventId
            return [pscustomobject]@{ Status = 'Failed'; EvidenceState = 'EvidenceMissing'; ReleaseLease = $true; CallbackEventId = $eventId; Handled = $true }
        }

        $progress = @{ automationJobId = [string]$job.JobId }
        if ($job.Status -eq 'Running') { $progress.status = 'Running' }
        elseif ($Request.status -eq 'Dispatching') { $progress.status = 'Dispatched' }
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties $progress
        return [pscustomobject]@{ Status = $progress.status; EvidenceState = $null; ReleaseLease = $false; CallbackEventId = $null; Handled = $false }
    }

    # --- Terminal Automation job: require valid evidence before declaring success ---
    $output = Get-AutomationRunbookJobOutput -JobName $jobName
    $result = ConvertFrom-RunbookOutput -Output ([string]$output)
    $evidenceState = Get-RunbookOutputEvidenceState -Output ([string]$output) -ParsedResult $result

    if ($evidenceState -ne 'HasResult') {
        $evidenceAttempts = 0
        $evidenceAttemptsValue = Get-JsonPropertyValue -InputObject $Request -Name 'evidenceAttempts'
        if ($evidenceAttemptsValue) { [int]::TryParse([string]$evidenceAttemptsValue, [ref] $evidenceAttempts) | Out-Null }
        $evidenceAttempts++

        if ($evidenceAttempts -ge (Get-EvidenceMaxAttempts) -or $expired) {
            $errorMessage = "Runbook job '$jobName' completed (status $($job.Status)) but produced no usable evidence after $evidenceAttempts attempt(s) (evidenceState=$evidenceState)."
            Write-AtLog -Level 'Error' -Message $errorMessage -Properties $logProps
            Write-AtAudit -Action 'WipeTerminalState' -Level 'Error' -Properties ($logProps + @{ status = 'Failed'; evidenceState = $evidenceState; errorMessage = $errorMessage })
            Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
                status = 'Failed'; errorMessage = $errorMessage; evidenceState = 'EvidenceMissing'
                jobStatus = [string]$job.Status; automationJobId = [string]$job.JobId; evidenceAttempts = $evidenceAttempts
                completedAt = (Get-Date).ToUniversalTime()
            }
            $eventId = Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl $callbackUrl -ExistingEventId $existingEventId
            return [pscustomobject]@{ Status = 'Failed'; EvidenceState = 'EvidenceMissing'; ReleaseLease = $true; CallbackEventId = $eventId; Handled = $true }
        }

        Write-AtLog -Level 'Warning' -Message "JobMonitor: job '$jobName' terminal but evidence not yet usable ($evidenceState), attempt $evidenceAttempts/$(Get-EvidenceMaxAttempts)." -Properties $logProps
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'EvidencePending'; jobStatus = [string]$job.Status; automationJobId = [string]$job.JobId
            evidenceState = $evidenceState; evidenceAttempts = $evidenceAttempts
        }
        return [pscustomobject]@{ Status = 'EvidencePending'; EvidenceState = $evidenceState; ReleaseLease = $false; CallbackEventId = $null; Handled = $false }
    }

    $status = Resolve-RequestTerminalStatus -JobStatus $job.Status -Result $result
    $errorMessage = ''
    if ($status -ne 'Completed') {
        $errorMessage = if ($job.Exception) { "$($job.Exception)" } elseif ($job.StatusDetails) { "$($job.StatusDetails)" } else { "Runbook job status: $($job.Status)" }
    }

    $updates = @{
        status          = $status
        completedAt     = (Get-Date).ToUniversalTime()
        jobStatus       = [string]$job.Status
        automationJobId = [string]$job.JobId
        errorMessage    = $errorMessage
        evidenceState   = 'HasResult'
        resultJson      = $result
    }
    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties $updates

    $logProps.status = $status
    Write-AtLog -Level 'Information' -Message 'JobMonitor: request reached a terminal state.' -Properties $logProps
    $auditLevel = if ($status -eq 'Completed') { 'Information' } elseif ($status -eq 'PartiallyCompleted') { 'Warning' } else { 'Error' }
    Write-AtAudit -Action 'WipeTerminalState' -Level $auditLevel -Properties ($logProps + @{ jobStatus = [string]$job.Status; errorMessage = $errorMessage })

    $eventId = Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl $callbackUrl -ExistingEventId $existingEventId
    return [pscustomobject]@{ Status = $status; EvidenceState = 'HasResult'; ReleaseLease = $true; CallbackEventId = $eventId; Handled = $true }
}

# ---------------------------------------------------------------------------
# Durable callback reconciliation
# ---------------------------------------------------------------------------
function Get-CallbackCandidateRequests {
    param([int] $Top = 200)
    return @(Find-WipeRequestState -Filter "callbackStatus eq 'Pending' or callbackStatus eq 'FailedRetryable'" -Top $Top)
}

function Test-CallbackAttemptDue {
    param($Request)
    return Test-BackoffFieldDue -Request $Request -FieldName 'callbackNextAttemptAt'
}

function Get-DueCallbackCandidates {
    param([int] $MaxConcurrency = -1)

    if ($MaxConcurrency -lt 0) { $MaxConcurrency = Get-CallbackMaxConcurrency }
    $candidates = @(Get-CallbackCandidateRequests | Where-Object { Test-CallbackAttemptDue -Request $_ })
    return @($candidates | Select-Object -First $MaxConcurrency)
}

function ConvertTo-CallbackPayload {
    <#
    .SYNOPSIS
        Builds the ServiceNow callback body from a durable state row. requestId
        and eventId are included in the body (not just the headers) so the
        receiver can de-duplicate even if it only inspects the payload.
    #>
    param($Request, [Parameter(Mandatory)] [string] $EventId)

    $result = $null
    $resultJson = Get-JsonPropertyValue -InputObject $Request -Name 'resultJson'
    if ($resultJson) {
        try { $result = [string]$resultJson | ConvertFrom-Json } catch { $result = [string]$resultJson }
    }

    return [ordered]@{
        requestId         = $Request.RowKey
        eventId           = $EventId
        correlationId     = Get-JsonPropertyValue -InputObject $Request -Name 'correlationId'
        platform          = $Request.PartitionKey
        scenario          = Get-JsonPropertyValue -InputObject $Request -Name 'scenario'
        status            = Get-JsonPropertyValue -InputObject $Request -Name 'status'
        dryRun            = Get-JsonPropertyValue -InputObject $Request -Name 'dryRun'
        device            = [ordered]@{
            serialNumber    = Get-JsonPropertyValue -InputObject $Request -Name 'serialNumber'
            imei            = Get-JsonPropertyValue -InputObject $Request -Name 'imei'
            deviceName      = Get-JsonPropertyValue -InputObject $Request -Name 'deviceName'
            managedDeviceId = Get-JsonPropertyValue -InputObject $Request -Name 'managedDeviceId'
        }
        automationJobName = Get-JsonPropertyValue -InputObject $Request -Name 'automationJobName'
        automationJobId   = Get-JsonPropertyValue -InputObject $Request -Name 'automationJobId'
        dispatchedAt      = Get-JsonPropertyValue -InputObject $Request -Name 'dispatchedAt'
        completedAt       = Get-JsonPropertyValue -InputObject $Request -Name 'completedAt'
        errorMessage      = Get-JsonPropertyValue -InputObject $Request -Name 'errorMessage'
        evidenceState     = Get-JsonPropertyValue -InputObject $Request -Name 'evidenceState'
        result            = $result
    }
}

function Send-WipeRequestCallback {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] $Payload,
        [Parameter(Mandatory)] [string] $EventId
    )

    $headers = @{
        'X-Request-Id'   = [string]$Payload.requestId
        'X-Event-Id'     = $EventId
        'Idempotency-Key' = $EventId
    }
    Invoke-RestMethod -Uri $Url -Method POST -Headers $headers -ContentType 'application/json' `
        -Body ($Payload | ConvertTo-Json -Depth 12) -TimeoutSec 30 | Out-Null
}

function Invoke-CallbackReconciliation {
    <#
    .SYNOPSIS
        Delivers (or retries) one durable callback. Claims the row with an
        ETag-conditional MERGE first so two JobMonitor passes can never send
        the same callback twice; reaches a final Sent/Failed state once
        delivered or once CALLBACK_MAX_ATTEMPTS is exhausted, otherwise
        schedules the next attempt with backoff (FailedRetryable).
    #>
    param([Parameter(Mandatory)] $Request)

    $platform = [string]$Request.PartitionKey
    $requestId = [string]$Request.RowKey

    $current = Get-WipeRequestStateWithETag -Platform $platform -RequestId $requestId
    if (-not $current) { return [pscustomobject]@{ Claimed = $false; Reason = 'NotFound'; Outcome = $null } }
    if ([string]$current.Entity.callbackStatus -notin @('Pending', 'FailedRetryable')) {
        return [pscustomobject]@{ Claimed = $false; Reason = 'NotEligible'; Outcome = $null }
    }

    $priorAttempts = 0
    $priorAttemptsValue = Get-JsonPropertyValue -InputObject $current.Entity -Name 'callbackAttempts'
    if ($priorAttemptsValue) { [int]::TryParse([string]$priorAttemptsValue, [ref] $priorAttempts) | Out-Null }
    $attempt = $priorAttempts + 1

    $claimed = Set-WipeRequestStateClaim -Platform $platform -RequestId $requestId -ETag $current.ETag -Properties @{
        callbackAttempts   = $attempt
        callbackClaimedAt  = (Get-Date).ToUniversalTime()
    }
    if (-not $claimed) { return [pscustomobject]@{ Claimed = $false; Reason = 'ClaimConflict'; Outcome = $null } }

    $callbackUrl = [string](Get-JsonPropertyValue -InputObject $current.Entity -Name 'callbackUrl')
    if ([string]::IsNullOrWhiteSpace($callbackUrl)) {
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{ callbackStatus = 'Failed'; callbackError = 'callbackUrl missing' }
        return [pscustomobject]@{ Claimed = $true; Reason = ''; Outcome = 'Failed' }
    }

    $eventId = [string](Get-JsonPropertyValue -InputObject $current.Entity -Name 'eventId')
    if ([string]::IsNullOrWhiteSpace($eventId)) { $eventId = [guid]::NewGuid().ToString() }

    $payload = ConvertTo-CallbackPayload -Request $current.Entity -EventId $eventId
    $logProps = @{ requestId = $requestId; platform = $platform; attempt = $attempt; eventId = $eventId }

    try {
        Send-WipeRequestCallback -Url $callbackUrl -Payload $payload -EventId $eventId
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            callbackStatus = 'Sent'; callbackSentAt = (Get-Date).ToUniversalTime(); callbackError = ''; eventId = $eventId
        }
        Write-AtAudit -Action 'WipeCallbackSent' -Properties $logProps
        return [pscustomobject]@{ Claimed = $true; Reason = ''; Outcome = 'Sent' }
    }
    catch {
        $maxAttempts = Get-CallbackMaxAttempts
        if ($attempt -ge $maxAttempts) {
            Write-AtLog -Level 'Error' -Message "JobMonitor: callback delivery failed permanently after $attempt attempts: $($_.Exception.Message)" -Properties $logProps
            Write-AtAudit -Action 'WipeCallbackFailed' -Level 'Error' -Properties ($logProps + @{ error = $_.Exception.Message })
            Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
                callbackStatus = 'Failed'; callbackError = $_.Exception.Message; eventId = $eventId
            }
            return [pscustomobject]@{ Claimed = $true; Reason = ''; Outcome = 'Failed' }
        }

        $delay = Get-BackoffDelaySeconds -Attempt $attempt -BaseSeconds (Get-CallbackBackoffBaseSeconds) -MaxSeconds (Get-CallbackBackoffMaxSeconds)
        $nextAttemptAt = (Get-Date).ToUniversalTime().AddSeconds($delay)
        Write-AtLog -Level 'Warning' -Message "JobMonitor: callback delivery failed (attempt $attempt/$maxAttempts), retrying at $($nextAttemptAt.ToString('o')): $($_.Exception.Message)" -Properties $logProps
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            callbackStatus = 'FailedRetryable'; callbackError = $_.Exception.Message
            callbackNextAttemptAt = $nextAttemptAt; eventId = $eventId
        }
        return [pscustomobject]@{ Claimed = $true; Reason = ''; Outcome = 'FailedRetryable' }
    }
}
# endregion Inlined functions from: AT.Dispatch.psm1

$dispatchCandidates = @(Get-DueDispatchCandidates)
Write-AtLog -Level 'Information' -Message "JobMonitor: $($dispatchCandidates.Count) request(s) due for a dispatch attempt."
foreach ($candidate in $dispatchCandidates) {
    $requestId = [string]$candidate.RowKey
    try {
        $reconciliation = Invoke-DispatchReconciliation -Request $candidate
        if (-not $reconciliation.Claimed) {
            Write-AtLog -Level 'Information' -Message "JobMonitor: dispatch claim skipped for '$requestId' ($($reconciliation.Reason))."
            continue
        }

        if ($reconciliation.Result.ReleaseLease) {
            try {
                Unlock-WipeDevice -SerialNumber ([string]$candidate.serialNumber) -RequestId $requestId | Out-Null
            }
            catch {
                Write-AtLog -Level 'Error' -Message "JobMonitor: failed to release the device lease for '$requestId': $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-AtLog -Level 'Error' -Message "JobMonitor: dispatch reconciliation failed for '$requestId': $($_.Exception.Message)"
    }
}

$inFlightCandidates = @(Get-InFlightCandidateRequests)
Write-AtLog -Level 'Information' -Message "JobMonitor: $($inFlightCandidates.Count) request(s) in flight."
foreach ($candidate in $inFlightCandidates) {
    $requestId = [string]$candidate.RowKey
    try {
        $reconciliation = Invoke-InFlightReconciliation -Request $candidate
        if ($reconciliation.ReleaseLease) {
            try {
                Unlock-WipeDevice -SerialNumber ([string]$candidate.serialNumber) -RequestId $requestId | Out-Null
            }
            catch {
                Write-AtLog -Level 'Error' -Message "JobMonitor: failed to release the device lease for '$requestId': $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-AtLog -Level 'Error' -Message "JobMonitor: in-flight reconciliation failed for '$requestId': $($_.Exception.Message)"
    }
}

$callbackCandidates = @(Get-DueCallbackCandidates)
Write-AtLog -Level 'Information' -Message "JobMonitor: $($callbackCandidates.Count) callback(s) due."
foreach ($candidate in $callbackCandidates) {
    $requestId = [string]$candidate.RowKey
    try {
        $reconciliation = Invoke-CallbackReconciliation -Request $candidate
        if (-not $reconciliation.Claimed) {
            Write-AtLog -Level 'Information' -Message "JobMonitor: callback claim skipped for '$requestId' ($($reconciliation.Reason))."
        }
    }
    catch {
        Write-AtLog -Level 'Error' -Message "JobMonitor: callback reconciliation failed for '$requestId': $($_.Exception.Message)"
    }
}

