#Requires -Version 7.6

# DispatchApple handler - Service Bus trigger on the 'sub-apple' subscription of the
# 'asset-disposal' topic. All platform dispatchers share one handler; the
# platform is asserted here so a mis-filtered message fails loudly.

param($Message, $TriggerMetadata)

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
# region Inlined functions from: AT.Automation.psm1
# Azure Automation runbook dispatch.
#
# Dispatch is always done through ARM:
#   PUT .../automationAccounts/{aa}/jobs/{jobName} with a managed-identity token.
# The client chooses jobName, so replaying the same Service Bus message never
# starts a duplicate job, and the job status/output can be polled
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

function ConvertFrom-RunbookOutput {
    <#
    .SYNOPSIS
        Extracts the structured result a runbook emits as a '##RESULT## {json}'
        line. Falls back to $null when the runbook has not been updated yet.
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
# endregion Inlined functions from: AT.Automation.psm1
# region Inlined functions from: AT.Dispatch.psm1
# Shared dispatch handler used by the three platform-specific Service Bus
# triggers (DispatchWindows / DispatchApple / DispatchAndroid).
#
# Responsibility: translate one canonical message into one Automation runbook
# job. It deliberately does NOT wait for the runbook to finish - JobMonitor
# reconciles the outcome over time.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function Invoke-DisposalDispatch {
    param(
        [Parameter(Mandatory)] $Message,
        [Parameter(Mandatory)] [string] $ExpectedPlatform
    )

    $payload = ConvertFrom-JsonBody -Body $Message
    if (-not $payload) { throw 'Service Bus message body is not valid JSON.' }

    $requestId = [string]$payload.requestId
    $platform = [string]$payload.platform

    if ([string]::IsNullOrWhiteSpace($requestId)) { throw 'Message is missing requestId.' }
    if ($platform -ne $ExpectedPlatform) {
        throw "Message platform '$platform' does not match the subscription platform '$ExpectedPlatform'."
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

    $logProps = @{
        requestId     = $requestId
        correlationId = [string]$payload.correlationId
        platform      = $platform
        scenario      = [string]$payload.scenario
        serialNumber  = [string]$payload.device.serialNumber
        dryRun        = $isDryRun
    }

    Write-AtLog -Level 'Information' -Message 'Dispatching disposal request.' -Properties $logProps
    Write-AtAudit -Action 'WipeDispatchStarted' -Properties $logProps

    # Retirement never removes the device from its enrollment platform. Until the
    # runbooks accept a -Scenario parameter, a retirement request must not be sent
    # to a runbook whose first action is the unenrollment.
    if (-not [bool]$payload.options.removeFromEnrollmentPlatform -and
        -not (Get-AppSettingBool -Name 'RUNBOOKS_SUPPORT_SCENARIO' -Default $false)) {
        $reason = 'Retirement scenario requires runbooks that support -Scenario; set RUNBOOKS_SUPPORT_SCENARIO=true once updated.'
        Write-AtLog -Level 'Warning' -Message $reason -Properties $logProps
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'DispatchFailed'; errorMessage = $reason
        }
        return
    }

    $binding = Resolve-RunbookBinding -Platform $platform -Message $payload

    # Idempotent job name: replaying the message returns the existing job.
    $jobName = $requestId

    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        status  = 'Dispatching'
        runbook = $binding.Runbook
        timeoutMinutes = $binding.TimeoutMinutes
    }

    if ($isDryRun) {
        Write-AtLog -Level 'Information' -Message 'Dry run: runbook not started.' -Properties $logProps
        Write-AtAudit -Action 'WipeDryRunCompleted' -Properties ($logProps + @{ status = 'Completed'; runbook = $binding.Runbook })
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'Completed'
            completedAt = (Get-Date).ToUniversalTime()
            resultJson = @{ dryRun = $true; runbook = $binding.Runbook; parameters = $binding.Parameters }
        }
        return
    }

    try {
        $job = Start-AutomationRunbookJob `
            -JobName $jobName `
            -Runbook $binding.Runbook `
            -Parameters $binding.Parameters `
            -RunOn $binding.RunOn
    }
    catch {
        # Let Service Bus retry transient failures; persist the attempt either way.
        Write-AtLog -Level 'Error' -Message "Runbook dispatch failed: $($_.Exception.Message)" -Properties $logProps
        Write-AtAudit -Action 'WipeDispatchFailed' -Level 'Error' -Properties ($logProps + @{ status = 'DispatchFailed'; error = $_.Exception.Message })
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'DispatchFailed'; errorMessage = $_.Exception.Message
        }
        throw
    }

    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        status            = 'Dispatched'
        automationJobName = [string]$job.JobName
        automationJobId   = [string]$job.JobId
        dispatchedAt      = (Get-Date).ToUniversalTime()
        errorMessage      = ''
    }

    $logProps.automationJobName = [string]$job.JobName
    Write-AtLog -Level 'Information' -Message 'Runbook job started.' -Properties $logProps
    Write-AtAudit -Action 'WipeJobStarted' -Properties ($logProps + @{ status = 'Dispatched'; runbook = $binding.Runbook; automationJobId = [string]$job.JobId })
}
# endregion Inlined functions from: AT.Dispatch.psm1


Invoke-DisposalDispatch -Message $Message -ExpectedPlatform 'Apple'
