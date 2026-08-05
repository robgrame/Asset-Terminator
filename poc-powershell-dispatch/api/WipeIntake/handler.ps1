#Requires -Version 7.6

using namespace System.Net

# WipeIntake handler - HTTP front door for ServiceNow.
#
# This function never wipes the device itself, and it never blocks on the
# runbook finishing. It:
#   1. validates the request;
#   2. atomically registers the requestId in a global index (PartitionKey
#      '__RequestId') so a retried/duplicated POST can never create two
#      dispatch attempts: same id + same content replays the current state,
#      same id + different content is rejected with 409 and never overwrites
#      the original. Every failure that can happen AFTER this registration but
#      BEFORE a durable Accepted/Rejected state row exists (a Graph failure, a
#      device-lease acquisition exception, an active-lease 409, the initial
#      Save-WipeRequestState failing, or even the persist of a Rejected
#      outcome itself failing) removes the index registration again, so a
#      same-payload retry always gets a full new attempt instead of being
#      trapped forever behind a hollow, never-finishing 202;
#   3. normalises operatingSystem -> enrollment platform (resolving the
#      ambiguous "Mobile" value against Intune) and rejects a payload whose
#      declared platform disagrees with Intune's authoritative record;
#   4. runs the fast, read-only guardrails (device managed by Intune,
#      encryption, user confirmation) and persists every Rejected outcome so
#      GetStatus can always answer for a requestId that was ever accepted for
#      processing;
#   5. persists the full canonical payload with status=Accepted BEFORE any
#      dispatch attempt is made (write-before-action / durable handoff): if
#      the Function App crashes or restarts right here, JobMonitor's
#      reconciliation pass still has everything it needs to dispatch the
#      runbook, because it reads this same persisted payload;
#   6. makes one optional, best-effort immediate dispatch attempt through
#      Azure Resource Manager. Success or failure of this attempt never
#      changes the durability guarantee from step 5: an ambiguous or
#      transient failure here is left for JobMonitor to retry with backoff,
#      never surfaced to the caller as a hard failure;
#   7. answers 202 Accepted with the requestId and a Location header.

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

    $payload = [ordered]@{
        timestamp     = (Get-Date).ToUniversalTime().ToString('o')
        level         = $Level
        message       = $Message
        correlationId = $Properties.correlationId
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

    $wipe = @($device.deviceActionResults) | Where-Object { $_.actionName -eq 'wipe' } | Select-Object -First 1

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

function Write-Json {
    param([int] $StatusCode, $Object, [hashtable] $ExtraHeaders)

    $headers = @{ 'Content-Type' = 'application/json' }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] } }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = $headers
        Body       = ($Object | ConvertTo-Json -Depth 10)
    })
}

function Remove-CurrentDeviceLease {
    param(
        [Parameter(Mandatory)] [string] $SerialNumber,
        [Parameter(Mandatory)] [string] $RequestId,
        [hashtable] $LogProperties
    )

    try {
        Unlock-WipeDevice -SerialNumber $SerialNumber -RequestId $RequestId | Out-Null
    }
    catch {
        Write-AtLog -Level 'Error' -Message "Failed to release the device lease: $($_.Exception.Message)" -Properties $LogProperties
    }
}

function Clear-RequestIdIndex {
    <#
    .SYNOPSIS
        Best-effort, idempotent cleanup of the global __RequestId index row
        for THIS caller's own registration. Must be invoked on every failure
        that happens strictly before a durable Accepted/Rejected state row
        has been written (a Graph failure, a device-lease acquisition
        exception, an active-lease 409, the initial Save-WipeRequestState
        failing, or a Rejected-state persist failing).
    .DESCRIPTION
        Without this cleanup, the registration made earlier in the request
        would remain permanently in place with no state row behind it: a
        future retry of the exact same payload would match the "safe replay"
        branch of Register-RequestIdIndex, find no state row, and hang
        forever on a hollow 202 "in flight" response that nothing is actually
        processing.

        This is deliberately best-effort and never throws: the failure that
        triggered this cleanup is what determines the HTTP response, and a
        secondary failure while cleaning up must not mask it. Any failure
        here is logged, never silently discarded.
    #>
    param(
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [string] $PayloadHash,
        [hashtable] $LogProperties
    )

    try {
        $removed = Remove-RequestIdIndex -RequestId $RequestId -PayloadHash $PayloadHash
        if (-not $removed) {
            Write-AtLog -Level 'Warning' -Message 'requestId index was left in place: a different registration (different payload) now owns it.' -Properties $LogProperties
        }
    }
    catch {
        Write-AtLog -Level 'Error' -Message "Failed to clean up the requestId index after a pre-persistence failure: $($_.Exception.Message)" -Properties $LogProperties
    }
}

function Save-RejectedRequest {
    <#
    .SYNOPSIS
        Persists every 'Rejected' outcome (reason/error/completedAt) so a
        requestId that reached domain-level validation never 404s on GetStatus,
        even though no dispatch was ever attempted for it.
    .OUTPUTS
        $true once the Rejected row is durably persisted. $false when the
        persist itself failed: the caller MUST fail closed in that case (see
        Complete-RejectedResponse) rather than answering 422 for a row that
        does not actually exist.
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [hashtable] $Properties,
        [hashtable] $LogProperties
    )

    try {
        Save-WipeRequestState -Platform $Platform -RequestId $RequestId -Properties (
            @{ status = 'Rejected'; completedAt = (Get-Date).ToUniversalTime() } + $Properties
        ) | Out-Null
        return $true
    }
    catch {
        Write-AtLog -Level 'Error' -Message "Failed to persist rejected state: $($_.Exception.Message)" -Properties $LogProperties
        return $false
    }
}

function Complete-RejectedResponse {
    <#
    .SYNOPSIS
        Persists a 'Rejected' outcome and answers 422 - UNLESS the persist
        itself fails, in which case this fails closed: it removes the
        __RequestId index registration (so the requestId genuinely never
        existed) and answers 502 instead.
    .DESCRIPTION
        Answering 422 when the durable Rejected row does not actually exist
        would let a same-payload retry fall into the "duplicate, in-flight"
        branch of the idempotency gate (Register-RequestIdIndex sees the same
        hash, but GetWipeRequestState/Find-WipeRequestState finds nothing) and
        hollow-202 forever, since nothing is ever going to finish "in flight".
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [string] $PayloadHash,
        [Parameter(Mandatory)] [string] $CorrelationId,
        [Parameter(Mandatory)] [hashtable] $StateProperties,
        [Parameter(Mandatory)] [hashtable] $ResponseBody,
        [hashtable] $LogProperties
    )

    $saved = Save-RejectedRequest -Platform $Platform -RequestId $RequestId -LogProperties $LogProperties -Properties $StateProperties
    if ($saved) {
        Write-Json -StatusCode 422 -Object $ResponseBody
        return
    }

    Clear-RequestIdIndex -RequestId $RequestId -PayloadHash $PayloadHash -LogProperties $LogProperties
    Write-Json -StatusCode 502 -Object @{
        error         = 'Failed to durably persist the rejected request outcome.'
        requestId     = $RequestId
        correlationId = $CorrelationId
    }
}

$payload = ConvertFrom-JsonBody -Body $Request.Body

# --- Validation -------------------------------------------------------------
if (-not $payload) {
    Write-Json -StatusCode 400 -Object @{ error = 'Request body must be valid JSON.' }
    return
}

$inputSerialNumber = [string](Get-JsonPropertyValue -InputObject $payload -Name 'serialNumber')
$inputImei = [string](Get-JsonPropertyValue -InputObject $payload -Name 'imei')
$inputManagedDeviceId = [string](Get-JsonPropertyValue -InputObject $payload -Name 'managedDeviceId')
$inputDeviceName = [string](Get-JsonPropertyValue -InputObject $payload -Name 'deviceName')
$inputScenario = [string](Get-JsonPropertyValue -InputObject $payload -Name 'scenario')
$inputOperatingSystem = [string](Get-JsonPropertyValue -InputObject $payload -Name 'operatingSystem')
$inputRequestId = [string](Get-JsonPropertyValue -InputObject $payload -Name 'requestId')
$inputDryRun = Get-JsonPropertyValue -InputObject $payload -Name 'dryRun'
$inputUserConfirmed = Get-JsonPropertyValue -InputObject $payload -Name 'userConfirmed'
$inputMdmServerId = [string](Get-JsonPropertyValue -InputObject $payload -Name 'mdmServerId')
$inputCallbackUrl = [string](Get-JsonPropertyValue -InputObject $payload -Name 'callbackUrl')

if (-not $inputSerialNumber -and -not $inputImei -and -not $inputManagedDeviceId -and -not $inputDeviceName) {
    Write-Json -StatusCode 400 -Object @{ error = 'At least one of serialNumber, imei, managedDeviceId or deviceName is required.' }
    return
}

$scenario = ConvertTo-ValidScenario -Scenario $inputScenario
if (-not $scenario) {
    Write-Json -StatusCode 400 -Object @{ error = 'scenario must be one of: Retirement, Sale, Disposal, LostStolen.' }
    return
}

$platform = ConvertTo-EnrollmentPlatform -OperatingSystem $inputOperatingSystem
if (-not $platform) {
    Write-Json -StatusCode 400 -Object @{ error = 'operatingSystem is required and must map to Windows, Apple or Android (aliases: win/macos/ios/ipados/android/mobile).' }
    return
}

$correlationId = [guid]::NewGuid().ToString()
$requestId = if ($inputRequestId) { $inputRequestId } else { $correlationId }

$dryRun = Get-AppSettingBool -Name 'DEFAULT_DRY_RUN' -Default $false
if ($null -ne $inputDryRun) { $dryRun = [System.Convert]::ToBoolean($inputDryRun) }

$logProps = @{
    correlationId = $correlationId
    requestId     = $requestId
    scenario      = $scenario
    platform      = $platform
    serialNumber  = $inputSerialNumber
    dryRun        = $dryRun
}

Write-AtLog -Level 'Information' -Message 'Disposal request received.' -Properties $logProps
Write-AtAudit -Action 'WipeRequestReceived' -Properties $logProps

# --- Atomic requestId idempotency gate ---------------------------------------
# The hash covers only what the CALLER supplied (never server-generated fields
# such as correlationId/acceptedAt): a legitimate retry of the exact same
# request must always compute the same hash so it can be replayed safely.
$hashInput = [ordered]@{
    requestId       = $requestId
    scenario        = $inputScenario
    operatingSystem = $inputOperatingSystem
    serialNumber    = $inputSerialNumber
    imei            = $inputImei
    managedDeviceId = $inputManagedDeviceId
    deviceName      = $inputDeviceName
    dryRun          = "$dryRun"
    userConfirmed   = "$([bool]$inputUserConfirmed)"
    mdmServerId     = $inputMdmServerId
    callbackUrl     = $inputCallbackUrl
}
$payloadHash = Get-PayloadHash -InputObject $hashInput

try {
    $registration = Register-RequestIdIndex -RequestId $requestId -Platform $platform -PayloadHash $payloadHash
}
catch {
    Write-AtLog -Level 'Error' -Message "State store idempotency check failed: $($_.Exception.Message)" -Properties $logProps
    Write-Json -StatusCode 502 -Object @{ error = 'Failed to check request idempotency.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

if (-not $registration.Registered) {
    if ($registration.Conflict) {
        Write-AtLog -Level 'Warning' -Message 'requestId reused with different content: rejected without overwriting the original request.' -Properties $logProps
        Write-AtAudit -Action 'WipeRequestIdConflict' -Level 'Warning' -Properties $logProps
        Write-Json -StatusCode 409 -Object @{
            error         = 'requestId was already used with different request content. Use a new requestId for a different request.'
            requestId     = $requestId
            correlationId = $correlationId
        }
        return
    }

    # Same requestId, same content: safe replay. Return the current durable
    # state instead of creating a second job.
    Write-AtLog -Level 'Warning' -Message 'Duplicate requestId with identical content, returning existing state.' -Properties $logProps
    $existing = $null
    try {
        # The index remembers the platform as first declared, which for a
        # "Mobile" request is resolved (Windows/Apple/Android excluded) only
        # AFTER the index write: the state row can therefore live in a
        # different partition than $registration.Platform. Try the fast path
        # first, then fall back to a partition-agnostic lookup by RowKey.
        $existing = Get-WipeRequestState -Platform $registration.Platform -RequestId $requestId
        if (-not $existing) {
            $candidates = @(Find-WipeRequestState -Filter "PartitionKey ne '__RequestId' and RowKey eq '$($requestId.Replace("'", "''"))'" -Top 1)
            if ($candidates.Count -gt 0) { $existing = $candidates[0] }
        }
    }
    catch {
        Write-AtLog -Level 'Warning' -Message "State store lookup for the existing request failed: $($_.Exception.Message)" -Properties $logProps
    }

    if ($existing) {
        Write-Json -StatusCode 200 -Object @{
            requestId     = $requestId
            correlationId = (Get-JsonPropertyValue -InputObject $existing -Name 'correlationId')
            status        = (Get-JsonPropertyValue -InputObject $existing -Name 'status')
            duplicate     = $true
        }
        return
    }

    # Registered a moment ago by a concurrent request that has not finished
    # persisting the state row yet: it is in flight, not lost.
    Write-Json -StatusCode 202 -Object @{
        requestId     = $requestId
        correlationId = $correlationId
        status        = 'Accepted'
        duplicate      = $true
    }
    return
}

# --- Device resolution + guardrails -----------------------------------------
$device = $null
try {
    $device = Get-IntuneManagedDevice `
        -ManagedDeviceId $inputManagedDeviceId `
        -DeviceName $inputDeviceName `
        -SerialNumber $inputSerialNumber `
        -Imei $inputImei `
        -LogProperties $logProps
}
catch {
    # A genuine Graph failure (auth, RBAC, throttling, 5xx, ...) is NEVER
    # reinterpreted as "device not managed": only an empty/404 result is.
    # This happens before any durable state row exists, so the __RequestId
    # registration made above must be undone: otherwise a retry of the exact
    # same payload would be trapped forever behind a hollow 202.
    Write-AtLog -Level 'Error' -Message "Device lookup failed: $($_.Exception.Message)" -Properties $logProps
    Clear-RequestIdIndex -RequestId $requestId -PayloadHash $payloadHash -LogProperties $logProps
    Write-Json -StatusCode 502 -Object @{ error = 'Failed to query Microsoft Graph for the device.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

# Guardrail: the process requires a manual task when the device is not managed.
if (-not $device) {
    Write-AtLog -Level 'Warning' -Message 'Managed device not found in Intune: routed to manual handling.' -Properties $logProps
    Write-AtAudit -Action 'WipeRequestRejected' -Level 'Warning' -Properties ($logProps + @{ status = 'Rejected'; reason = 'DeviceNotManagedByIntune' })
    Complete-RejectedResponse -Platform $platform -RequestId $requestId -PayloadHash $payloadHash -CorrelationId $correlationId -LogProperties $logProps `
        -StateProperties @{
            correlationId = $correlationId; scenario = $scenario; serialNumber = $inputSerialNumber; imei = $inputImei
            reason = 'DeviceNotManagedByIntune'
            errorMessage = 'Managed device not found in Intune. ServiceNow must open a manual task.'
        } `
        -ResponseBody @{
            requestId     = $requestId
            correlationId = $correlationId
            status        = 'Rejected'
            reason        = 'DeviceNotManagedByIntune'
            error         = 'Managed device not found in Intune. ServiceNow must open a manual task.'
        }
    return
}

# "Mobile" is ambiguous: Intune is the authoritative source for iOS vs Android.
if ($platform -eq 'Mobile') {
    $platform = ConvertTo-EnrollmentPlatform -OperatingSystem ([string]$device.operatingSystem)
    if (-not $platform -or $platform -eq 'Mobile') {
        Complete-RejectedResponse -Platform 'Mobile' -RequestId $requestId -PayloadHash $payloadHash -CorrelationId $correlationId -LogProperties $logProps `
            -StateProperties @{
                correlationId = $correlationId; scenario = $scenario; serialNumber = [string]$device.serialNumber
                managedDeviceId = [string]$device.id; deviceName = [string]$device.deviceName
                reason = 'AmbiguousPlatform'
                errorMessage = "Unable to resolve the enrollment platform from Intune operatingSystem '$($device.operatingSystem)'."
            } `
            -ResponseBody @{
                requestId = $requestId; correlationId = $correlationId; status = 'Rejected'
                reason = 'AmbiguousPlatform'
                error  = "Unable to resolve the enrollment platform from Intune operatingSystem '$($device.operatingSystem)'."
            }
        return
    }
    $logProps.platform = $platform
}
else {
    # The caller declared a concrete platform: Intune's own record is still
    # authoritative and a mismatch must be rejected rather than silently
    # dispatched to the wrong runbook.
    $intunePlatform = ConvertTo-EnrollmentPlatform -OperatingSystem ([string]$device.operatingSystem)
    if ($intunePlatform -and $intunePlatform -ne 'Mobile' -and $intunePlatform -ne $platform) {
        Write-AtLog -Level 'Warning' -Message "Payload platform '$platform' does not match Intune's operatingSystem '$($device.operatingSystem)' (resolved '$intunePlatform')." -Properties $logProps
        Write-AtAudit -Action 'WipeRequestRejected' -Level 'Warning' -Properties ($logProps + @{ status = 'Rejected'; reason = 'PlatformMismatch' })
        Complete-RejectedResponse -Platform $platform -RequestId $requestId -PayloadHash $payloadHash -CorrelationId $correlationId -LogProperties $logProps `
            -StateProperties @{
                correlationId = $correlationId; scenario = $scenario; serialNumber = [string]$device.serialNumber
                managedDeviceId = [string]$device.id; deviceName = [string]$device.deviceName
                reason = 'PlatformMismatch'
                errorMessage = "Requested platform '$platform' does not match the device's Intune platform '$intunePlatform'."
            } `
            -ResponseBody @{
                requestId = $requestId; correlationId = $correlationId; status = 'Rejected'
                reason = 'PlatformMismatch'
                error  = "Requested platform '$platform' does not match the device's Intune platform '$intunePlatform' (operatingSystem='$($device.operatingSystem)')."
            }
        return
    }
}

# When the caller supplied an IMEI, it must belong to the resolved device:
# otherwise the wrong physical asset could be wiped under the right serial.
if (-not [string]::IsNullOrWhiteSpace($inputImei) -and
    -not [string]::IsNullOrWhiteSpace([string]$device.imei) -and
    $inputImei -ne [string]$device.imei) {
    Write-AtLog -Level 'Warning' -Message 'Supplied imei does not match the resolved device record.' -Properties $logProps
    Write-AtAudit -Action 'WipeRequestRejected' -Level 'Warning' -Properties ($logProps + @{ status = 'Rejected'; reason = 'DeviceIdentityMismatch' })
    Complete-RejectedResponse -Platform $platform -RequestId $requestId -PayloadHash $payloadHash -CorrelationId $correlationId -LogProperties $logProps `
        -StateProperties @{
            correlationId = $correlationId; scenario = $scenario; serialNumber = [string]$device.serialNumber
            managedDeviceId = [string]$device.id; deviceName = [string]$device.deviceName; imei = $inputImei
            reason = 'DeviceIdentityMismatch'
            errorMessage = "Supplied imei '$inputImei' does not match the resolved device's imei."
        } `
        -ResponseBody @{
            requestId = $requestId; correlationId = $correlationId; status = 'Rejected'
            reason = 'DeviceIdentityMismatch'
            error  = "Supplied imei does not match the resolved device's imei."
        }
    return
}

$resolvedSerialNumber = [string]$device.serialNumber
if ([string]::IsNullOrWhiteSpace($resolvedSerialNumber)) {
    Write-AtLog -Level 'Warning' -Message 'The managed device has no serial number and cannot be dispatched.' -Properties $logProps
    Complete-RejectedResponse -Platform $platform -RequestId $requestId -PayloadHash $payloadHash -CorrelationId $correlationId -LogProperties $logProps `
        -StateProperties @{
            correlationId = $correlationId; scenario = $scenario; managedDeviceId = [string]$device.id; deviceName = [string]$device.deviceName
            reason = 'MissingSerialNumber'
            errorMessage = 'The managed device does not expose the serial number required by the platform runbook.'
        } `
        -ResponseBody @{
            requestId = $requestId
            correlationId = $correlationId
            status = 'Rejected'
            reason = 'MissingSerialNumber'
            error = 'The managed device does not expose the serial number required by the platform runbook.'
        }
    return
}
$logProps.serialNumber = $resolvedSerialNumber

$guardrails = [System.Collections.Generic.List[object]]::new()

if (Get-AppSettingBool -Name 'GUARDRAIL_REQUIRE_ENCRYPTION' -Default $true) {
    $encrypted = [bool]$device.isEncrypted
    $guardrails.Add([pscustomobject]@{ name = 'Encryption'; passed = $encrypted; detail = "isEncrypted=$encrypted" })
}

if (Get-AppSettingBool -Name 'GUARDRAIL_REQUIRE_USER_CONFIRMATION' -Default $true) {
    $confirmed = [bool]$inputUserConfirmed
    $guardrails.Add([pscustomobject]@{ name = 'UserConfirmation'; passed = $confirmed; detail = "userConfirmed=$confirmed" })
}

$failed = @($guardrails | Where-Object { -not $_.passed })
if ($failed.Count -gt 0 -and -not $dryRun) {
    Write-AtLog -Level 'Warning' -Message 'Guardrails failed: routed to manual handling.' -Properties $logProps
    Write-AtAudit -Action 'WipeRequestRejected' -Level 'Warning' -Properties ($logProps + @{ status = 'Rejected'; reason = 'GuardrailFailed'; guardrails = (($failed.name) -join ',') })

    Complete-RejectedResponse -Platform $platform -RequestId $requestId -PayloadHash $payloadHash -CorrelationId $correlationId -LogProperties $logProps `
        -StateProperties @{
            correlationId = $correlationId; scenario = $scenario
            serialNumber  = [string]$device.serialNumber; deviceName = [string]$device.deviceName
            managedDeviceId = [string]$device.id
            reason        = 'GuardrailFailed'
            errorMessage  = "Guardrails failed: $(($failed.name) -join ', ')"
        } `
        -ResponseBody @{
            requestId = $requestId; correlationId = $correlationId; status = 'Rejected'
            reason = 'GuardrailFailed'; guardrails = $guardrails
        }
    return
}

# --- Canonical message -------------------------------------------------------
$removeFromPlatform = Test-RemoveFromEnrollmentPlatform -Scenario $scenario

$message = [ordered]@{
    schemaVersion = '1.0'
    requestId     = $requestId
    correlationId = $correlationId
    platform      = $platform
    scenario      = $scenario
    device        = [ordered]@{
        serialNumber    = [string]$device.serialNumber
        imei            = $inputImei
        deviceName      = [string]$device.deviceName
        managedDeviceId = [string]$device.id
        operatingSystem = [string]$device.operatingSystem
        osVersion       = [string]$device.osVersion
        isEncrypted     = [bool]$device.isEncrypted
    }
    options       = [ordered]@{
        removeFromEnrollmentPlatform = $removeFromPlatform
        keepUserData                 = (Get-AppSettingBool -Name 'WIPE_KEEP_USER_DATA' -Default $false)
        keepEnrollmentData           = (Get-AppSettingBool -Name 'WIPE_KEEP_ENROLLMENT_DATA' -Default $false)
        mdmServerId                  = $inputMdmServerId
        dryRun                       = $dryRun
    }
    callbackUrl   = $inputCallbackUrl
    acceptedAt    = (Get-Date).ToUniversalTime().ToString('o')
}

try {
    $deviceLease = Lock-WipeDevice `
        -SerialNumber $resolvedSerialNumber `
        -RequestId $requestId `
        -Platform $platform
}
catch {
    # No durable state row exists yet: undo the __RequestId registration so a
    # retry of the exact same payload gets a full new attempt rather than a
    # hollow 202 forever.
    Write-AtLog -Level 'Error' -Message "Failed to acquire the device lease: $($_.Exception.Message)" -Properties $logProps
    Clear-RequestIdIndex -RequestId $requestId -PayloadHash $payloadHash -LogProperties $logProps
    Write-Json -StatusCode 500 -Object @{
        error = 'Failed to reserve the device for this request.'
        detail = $_.Exception.Message
        correlationId = $correlationId
    }
    return
}

if (-not $deviceLease.Acquired) {
    # A transient/legitimate 409 (another disposal is genuinely in progress
    # for the device), but still strictly before any durable state row for
    # THIS requestId exists. Clean up the index instead of persisting a
    # terminal outcome for what may resolve itself once the other lease
    # expires: this keeps a same-payload retry re-evaluating from scratch
    # (and getting another accurate 409, never a stranded hollow 202).
    Write-AtLog -Level 'Warning' -Message "Another disposal request is active for this device: $($deviceLease.ActiveRequestId)." -Properties $logProps
    Clear-RequestIdIndex -RequestId $requestId -PayloadHash $payloadHash -LogProperties $logProps
    Write-Json -StatusCode 409 -Object @{
        error = 'Another disposal request is already active for this device.'
        requestId = $requestId
        activeRequestId = $deviceLease.ActiveRequestId
        activePlatform = $deviceLease.ActivePlatform
        leaseExpiresAt = $deviceLease.ExpiresAt
        correlationId = $correlationId
    }
    return
}

# --- Write-before-action: durable handoff ------------------------------------
# The full canonical payload is persisted BEFORE any dispatch attempt. If the
# process is recycled right here, JobMonitor's reconciliation pass finds this
# same row (status=Accepted, payloadJson set) and dispatches it - no HTTP
# request needs to be replayed for the disposal to still happen.
try {
    Save-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        correlationId   = $correlationId
        status          = 'Accepted'
        scenario        = $scenario
        serialNumber    = [string]$device.serialNumber
        imei            = $inputImei
        deviceName      = [string]$device.deviceName
        managedDeviceId = [string]$device.id
        operatingSystem = [string]$device.operatingSystem
        callbackUrl     = $inputCallbackUrl
        dryRun          = $dryRun
        attempts        = 0
        payloadHash     = $payloadHash
        payloadJson     = $message
        acceptedAt      = (Get-Date).ToUniversalTime()
    } | Out-Null
}
catch {
    Write-AtLog -Level 'Error' -Message "Failed to persist state: $($_.Exception.Message)" -Properties $logProps
    Remove-CurrentDeviceLease -SerialNumber $resolvedSerialNumber -RequestId $requestId -LogProperties $logProps
    Clear-RequestIdIndex -RequestId $requestId -PayloadHash $payloadHash -LogProperties $logProps
    Write-Json -StatusCode 500 -Object @{ error = 'Failed to persist the request state.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

# --- Optional immediate dispatch attempt -------------------------------------
# Best-effort only: claim the row we just created (an ETag-conditional MERGE,
# exactly like JobMonitor's reconciliation pass uses) so this attempt and a
# concurrent JobMonitor tick can never both start the runbook job. If the
# claim is lost, JobMonitor already owns the request and will finish it; the
# caller simply gets 202 Accepted back.
$dispatch = $null
try {
    $claim = Invoke-DispatchClaim -Platform $platform -RequestId $requestId
    if ($claim.Claimed) {
        $dispatch = Invoke-DisposalDispatch -Message $message -ExpectedPlatform $platform -Attempt 1
    }
    else {
        Write-AtLog -Level 'Information' -Message "Immediate dispatch skipped ($($claim.Reason)); JobMonitor will reconcile." -Properties $logProps
    }
}
catch {
    # The immediate attempt is an optimisation: any unexpected failure here
    # (including a claim/dispatch bug) must not surface as an HTTP failure,
    # because the durable Accepted row already guarantees JobMonitor will try.
    Write-AtLog -Level 'Error' -Message "Immediate dispatch attempt failed unexpectedly, deferring to JobMonitor: $($_.Exception.Message)" -Properties $logProps
}

if (-not $dispatch) {
    Write-AtAudit -Action 'WipeRequestAccepted' -Properties ($logProps + @{ status = 'Accepted' })
    Write-Json -StatusCode 202 -Object @{
        requestId     = $requestId
        correlationId = $correlationId
        status        = 'Accepted'
        platform      = $platform
        scenario      = $scenario
        dryRun        = $dryRun
        device        = @{
            managedDeviceId = [string]$device.id
            deviceName      = [string]$device.deviceName
            serialNumber    = [string]$device.serialNumber
            operatingSystem = [string]$device.operatingSystem
        }
        guardrails    = $guardrails
        statusUrl     = "/api/v1/wipe/status?requestId=$requestId"
    } -ExtraHeaders @{ 'Location' = "/api/v1/wipe/status?requestId=$requestId" }
    return
}

if ($dispatch.ReleaseLease) {
    Remove-CurrentDeviceLease -SerialNumber $resolvedSerialNumber -RequestId $requestId -LogProperties $logProps
}

if ($dispatch.Status -eq 'DispatchFailed') {
    Write-Json -StatusCode 500 -Object @{
        error = $dispatch.ErrorMessage
        requestId = $requestId
        correlationId = $correlationId
        status = $dispatch.Status
    }
    return
}

Write-AtLog -Level 'Information' -Message 'Disposal request dispatched directly.' -Properties $logProps
Write-AtAudit -Action 'WipeRequestAccepted' -Properties ($logProps + @{ status = $dispatch.Status })

Write-Json -StatusCode 202 -Object @{
    requestId     = $requestId
    correlationId = $correlationId
    status        = $dispatch.Status
    platform      = $platform
    scenario      = $scenario
    dryRun        = $dryRun
    device        = @{
        managedDeviceId = [string]$device.id
        deviceName      = [string]$device.deviceName
        serialNumber    = [string]$device.serialNumber
        operatingSystem = [string]$device.operatingSystem
    }
    guardrails        = $guardrails
    automationJobName = $dispatch.AutomationJobName
    automationJobId   = $dispatch.AutomationJobId
    statusUrl         = "/api/v1/wipe/status?requestId=$requestId"
} -ExtraHeaders @{ 'Location' = "/api/v1/wipe/status?requestId=$requestId" }
