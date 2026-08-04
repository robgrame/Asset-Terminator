#Requires -Version 7.6

using namespace System.Net

# WipeIntake handler - HTTP front door for ServiceNow.
#
# Unlike the synchronous mock, this function never touches the device. It:
#   1. validates the request;
#   2. normalises operatingSystem -> enrollment platform (resolving the ambiguous
#      "Mobile" value against Intune);
#   3. runs the fast, read-only guardrails (device managed by Intune, encryption,
#      user confirmation);
#   4. persists the request state (write-before-action);
#   5. publishes the canonical message on the Service Bus topic;
#   6. answers 202 Accepted with the requestId and a Location header.
#
# The actual wipe is performed by the platform runbooks, started by the worker.

param($Request, $TriggerMetadata)

# -----------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT DIRECTLY.
# Source handler: handler.ps1
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
            Resolves an Intune managed device by managedDeviceId, or by deviceName
            and/or serialNumber. When several stale objects match, the freshest one
            (by enrolledDateTime, then lastSyncDateTime) is returned.
        .OUTPUTS
            The managedDevice Graph object, or $null when not found.
    #>
    [CmdletBinding()]
    param(
        [string] $ManagedDeviceId,
        [string] $DeviceName,
        [string] $SerialNumber,
        [hashtable] $LogProperties = @{}
    )

    $select = 'id,deviceName,operatingSystem,osVersion,isEncrypted,complianceState,enrolledDateTime,lastSyncDateTime,userPrincipalName,serialNumber,manufacturer'

    if ($ManagedDeviceId) {
        try {
            return Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices/$ManagedDeviceId`?`$select=$select"
        }
        catch { return $null }
    }

    if (-not $DeviceName -and -not $SerialNumber) {
        throw 'Get-IntuneManagedDevice requires -ManagedDeviceId, -DeviceName or -SerialNumber.'
    }

    $clauses = @()
    if ($DeviceName)   { $clauses += "deviceName eq '$($DeviceName.Replace("'", "''"))'" }
    if ($SerialNumber) { $clauses += "serialNumber eq '$($SerialNumber.Replace("'", "''"))'" }
    $filter = [Uri]::EscapeDataString($clauses -join ' and ')

    $candidates = @()
    try {
        $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$filter=$filter&`$select=$select"
        $candidates = @($result.value)
    }
    catch {
        Write-MockLog -Level 'Warning' -Message "Server-side filter failed ($($_.Exception.Message)); falling back to client-side matching." -Properties $LogProperties
        if ($DeviceName) {
            $nameFilter = [Uri]::EscapeDataString("deviceName eq '$($DeviceName.Replace("'", "''"))'")
            $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$filter=$nameFilter&`$select=$select"
        }
        else {
            $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$select=$select"
        }
        $candidates = @($result.value)
    }

    if ($DeviceName)   { $candidates = @($candidates | Where-Object { $_.deviceName   -eq $DeviceName }) }
    if ($SerialNumber) { $candidates = @($candidates | Where-Object { $_.serialNumber -eq $SerialNumber }) }

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
# region Inlined functions from: AT.Messaging.psm1
# Service Bus publishing over the REST API with a managed-identity token.
#
# The REST API is used instead of an output binding because the pipeline needs
# per-message brokered properties that the PowerShell output binding does not
# expose: MessageId (duplicate detection), SessionId (per-device ordering) and
# custom application properties (the SQL filters of the topic subscriptions).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function Send-ServiceBusMessage {
    param(
        [Parameter(Mandatory)] [string] $Entity,
        [Parameter(Mandatory)] $Body,
        [Parameter(Mandatory)] [string] $MessageId,
        [string] $SessionId,
        [string] $CorrelationId,
        [hashtable] $ApplicationProperties
    )

    $namespace = Get-AppSetting -Name 'SERVICEBUS_FQDN' -Required
    $uri = "https://$namespace/$Entity/messages"

    $token = Get-ManagedIdentityToken -Resource 'https://servicebus.azure.net/'

    $brokerProperties = @{ MessageId = $MessageId }
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) { $brokerProperties['SessionId'] = $SessionId }
    if (-not [string]::IsNullOrWhiteSpace($CorrelationId)) { $brokerProperties['CorrelationId'] = $CorrelationId }

    $headers = @{
        'Authorization'    = "Bearer $token"
        'BrokerProperties' = ($brokerProperties | ConvertTo-Json -Compress)
    }

    # Custom application properties travel as HTTP headers; string values must be
    # quoted so Service Bus types them as strings rather than as raw tokens.
    if ($ApplicationProperties) {
        foreach ($key in $ApplicationProperties.Keys) {
            $value = $ApplicationProperties[$key]
            if ($null -eq $value) { continue }
            if ($value -is [bool]) {
                $headers[$key] = $value.ToString().ToLowerInvariant()
            }
            elseif ($value -is [int] -or $value -is [long] -or $value -is [double]) {
                $headers[$key] = "$value"
            }
            else {
                $headers[$key] = '"' + ("$value").Replace('"', '\"') + '"'
            }
        }
    }

    $payload = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 12 }

    Invoke-RestMethod -Uri $uri -Method POST -Headers $headers `
        -ContentType 'application/json;charset=utf-8' -Body $payload | Out-Null

    return $MessageId
}
# endregion Inlined functions from: AT.Messaging.psm1


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

$payload = ConvertFrom-JsonBody -Body $Request.Body

# --- Validation -------------------------------------------------------------
if (-not $payload) {
    Write-Json -StatusCode 400 -Object @{ error = 'Request body must be valid JSON.' }
    return
}

if (-not $payload.serialNumber -and -not $payload.imei -and -not $payload.managedDeviceId -and -not $payload.deviceName) {
    Write-Json -StatusCode 400 -Object @{ error = 'At least one of serialNumber, imei, managedDeviceId or deviceName is required.' }
    return
}

$scenario = ConvertTo-ValidScenario -Scenario ([string]$payload.scenario)
if (-not $scenario) {
    Write-Json -StatusCode 400 -Object @{ error = 'scenario must be one of: Retirement, Sale, Disposal, LostStolen.' }
    return
}

$platform = ConvertTo-EnrollmentPlatform -OperatingSystem ([string]$payload.operatingSystem)
if (-not $platform) {
    Write-Json -StatusCode 400 -Object @{ error = 'operatingSystem is required and must map to Windows, Apple or Android (aliases: win/macos/ios/ipados/android/mobile).' }
    return
}

$correlationId = [guid]::NewGuid().ToString()
$requestId = if ($payload.requestId) { [string]$payload.requestId } else { $correlationId }

$dryRun = Get-AppSettingBool -Name 'DEFAULT_DRY_RUN' -Default $false
if ($null -ne $payload.dryRun) { $dryRun = [System.Convert]::ToBoolean($payload.dryRun) }

$logProps = @{
    correlationId = $correlationId
    requestId     = $requestId
    scenario      = $scenario
    platform      = $platform
    serialNumber  = [string]$payload.serialNumber
    dryRun        = $dryRun
}

Write-AtLog -Level 'Information' -Message 'Disposal request received.' -Properties $logProps
Write-AtAudit -Action 'WipeRequestReceived' -Properties $logProps

# --- Idempotency ------------------------------------------------------------
# Same requestId already in flight or done: return the current state instead of
# creating a second job. Service Bus duplicate detection is the second line of
# defence, this one keeps the answer meaningful for ServiceNow.
try {
    $existing = Find-WipeRequestState -Filter "RowKey eq '$requestId'" -Top 1
    if ($existing.Count -gt 0) {
        Write-AtLog -Level 'Warning' -Message 'Duplicate requestId, returning existing state.' -Properties $logProps
        Write-Json -StatusCode 200 -Object @{
            requestId     = $requestId
            correlationId = $existing[0].correlationId
            status        = $existing[0].status
            duplicate     = $true
        }
        return
    }
}
catch {
    Write-AtLog -Level 'Warning' -Message "State store lookup failed, continuing: $($_.Exception.Message)" -Properties $logProps
}

# --- Device resolution + guardrails -----------------------------------------
$device = $null
try {
    $device = Get-IntuneManagedDevice `
        -ManagedDeviceId ([string]$payload.managedDeviceId) `
        -DeviceName ([string]$payload.deviceName) `
        -SerialNumber ([string]$payload.serialNumber) `
        -LogProperties $logProps
}
catch {
    Write-AtLog -Level 'Error' -Message "Device lookup failed: $($_.Exception.Message)" -Properties $logProps
    Write-Json -StatusCode 502 -Object @{ error = 'Failed to query Microsoft Graph for the device.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

# Guardrail: the process requires a manual task when the device is not managed.
if (-not $device) {
    Write-AtLog -Level 'Warning' -Message 'Managed device not found in Intune: routed to manual handling.' -Properties $logProps
    Write-AtAudit -Action 'WipeRequestRejected' -Level 'Warning' -Properties ($logProps + @{ status = 'Rejected'; reason = 'DeviceNotManagedByIntune' })
    Write-Json -StatusCode 422 -Object @{
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
        Write-Json -StatusCode 422 -Object @{
            requestId = $requestId; correlationId = $correlationId; status = 'Rejected'
            reason = 'AmbiguousPlatform'
            error  = "Unable to resolve the enrollment platform from Intune operatingSystem '$($device.operatingSystem)'."
        }
        return
    }
    $logProps.platform = $platform
}

$guardrails = [System.Collections.Generic.List[object]]::new()

if (Get-AppSettingBool -Name 'GUARDRAIL_REQUIRE_ENCRYPTION' -Default $true) {
    $encrypted = [bool]$device.isEncrypted
    $guardrails.Add([pscustomobject]@{ name = 'Encryption'; passed = $encrypted; detail = "isEncrypted=$encrypted" })
}

if (Get-AppSettingBool -Name 'GUARDRAIL_REQUIRE_USER_CONFIRMATION' -Default $true) {
    $confirmed = [bool]$payload.userConfirmed
    $guardrails.Add([pscustomobject]@{ name = 'UserConfirmation'; passed = $confirmed; detail = "userConfirmed=$confirmed" })
}

$failed = @($guardrails | Where-Object { -not $_.passed })
if ($failed.Count -gt 0 -and -not $dryRun) {
    Write-AtLog -Level 'Warning' -Message 'Guardrails failed: routed to manual handling.' -Properties $logProps
    Write-AtAudit -Action 'WipeRequestRejected' -Level 'Warning' -Properties ($logProps + @{ status = 'Rejected'; reason = 'GuardrailFailed'; guardrails = (($failed.name) -join ',') })

    try {
        Save-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            correlationId = $correlationId; status = 'Rejected'; scenario = $scenario
            serialNumber  = [string]$device.serialNumber; deviceName = [string]$device.deviceName
            managedDeviceId = [string]$device.id
            errorMessage  = "Guardrails failed: $(($failed.name) -join ', ')"
            acceptedAt    = (Get-Date).ToUniversalTime()
        } | Out-Null
    }
    catch { Write-AtLog -Level 'Error' -Message "Failed to persist rejected state: $($_.Exception.Message)" -Properties $logProps }

    Write-Json -StatusCode 422 -Object @{
        requestId = $requestId; correlationId = $correlationId; status = 'Rejected'
        reason = 'GuardrailFailed'; guardrails = $guardrails
    }
    return
}

# --- Canonical message ------------------------------------------------------
$removeFromPlatform = Test-RemoveFromEnrollmentPlatform -Scenario $scenario

$message = [ordered]@{
    schemaVersion = '1.0'
    requestId     = $requestId
    correlationId = $correlationId
    platform      = $platform
    scenario      = $scenario
    device        = [ordered]@{
        serialNumber    = [string]$device.serialNumber
        imei            = [string]$payload.imei
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
        mdmServerId                  = [string]$payload.mdmServerId
        dryRun                       = $dryRun
    }
    callbackUrl   = [string]$payload.callbackUrl
    enqueuedAt    = (Get-Date).ToUniversalTime().ToString('o')
}

# --- Write-before-action ----------------------------------------------------
try {
    Save-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        correlationId   = $correlationId
        status          = 'Accepted'
        scenario        = $scenario
        serialNumber    = [string]$device.serialNumber
        imei            = [string]$payload.imei
        deviceName      = [string]$device.deviceName
        managedDeviceId = [string]$device.id
        operatingSystem = [string]$device.operatingSystem
        callbackUrl     = [string]$payload.callbackUrl
        dryRun          = $dryRun
        attempts        = 0
        acceptedAt      = (Get-Date).ToUniversalTime()
    } | Out-Null
}
catch {
    Write-AtLog -Level 'Error' -Message "Failed to persist state: $($_.Exception.Message)" -Properties $logProps
    Write-Json -StatusCode 500 -Object @{ error = 'Failed to persist the request state.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

# --- Publish ----------------------------------------------------------------
try {
    Send-ServiceBusMessage `
        -Entity (Get-AppSetting -Name 'SERVICEBUS_TOPIC' -Default 'asset-disposal') `
        -Body $message `
        -MessageId $requestId `
        -SessionId ([string]$device.serialNumber) `
        -CorrelationId $correlationId `
        -ApplicationProperties @{ platform = $platform; scenario = $scenario; dryRun = $dryRun } | Out-Null

    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        status = 'Queued'; queuedAt = (Get-Date).ToUniversalTime()
    }
}
catch {
    Write-AtLog -Level 'Error' -Message "Failed to publish message: $($_.Exception.Message)" -Properties $logProps
    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        status = 'Rejected'; errorMessage = "Publish failed: $($_.Exception.Message)"
    }
    Write-Json -StatusCode 500 -Object @{ error = 'Failed to queue the request.'; detail = $_.Exception.Message; correlationId = $correlationId }
    return
}

Write-AtLog -Level 'Information' -Message 'Disposal request queued.' -Properties $logProps
Write-AtAudit -Action 'WipeRequestQueued' -Properties ($logProps + @{ status = 'Queued' })

Write-Json -StatusCode 202 -Object @{
    requestId     = $requestId
    correlationId = $correlationId
    status        = 'Queued'
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
