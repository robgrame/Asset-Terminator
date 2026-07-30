#Requires -Version 7.4
<#
.SYNOPSIS
    Apple Business Manager unassign + Intune wipe. Corrected version for the
    Service Bus dispatch pipeline.

.DESCRIPTION
    Corrections and changes vs the original APPLE_Device_Disposal.ps1:

      * FIXED (blocking): the Authorization header was the literal string
        '******' instead of "Bearer <token>", so every ABM API call returned
        401. The runbook as delivered could not work.
      * FIXED: the ABM unassign result was never inspected. A failed activity
        was logged with Write-Error but the runbook carried on to the wipe and
        still "succeeded". The activity is now polled to a terminal state and
        the outcome drives the result.
      * REPLACED: the blind 'Start-Sleep 15 minutes' before the wipe. The
        runbook now polls depOnboardingSettings until lastSuccessfulSyncDateTime
        actually advances past the moment the sync was requested, with the wait
        as an upper bound. On a fast tenant this saves ~14 minutes of Automation
        job time; on a slow one it waits as long as it really needs to.
      * REMOVED: the -WebhookData branch. The dispatcher starts the runbook with
        named parameters through ARM.
      * ADDED: -RequestId, -Scenario, -DryRun and -DepTokenId.
      * ADDED: the '##RESULT## {json}' structured output line.
      * ADDED: the runbook fails when no wipe could be issued.

    Scenario semantics:
      Retirement  wipe only, the device stays assigned in ABM
      Sale        unassign from the MDM server in ABM, then wipe
      Disposal    unassign from the MDM server in ABM, then wipe
      LostStolen  wipe only, the device stays assigned for tracking

    CREDENTIALS
    All credentials are read from encrypted Azure Automation variables. Nothing
    secret is ever accepted as a runbook parameter: job parameters are stored in
    clear text in the job metadata and are visible to any Job Reader.

      ABM-ClientId            e.g. BUSINESSAPI.<guid>
      ABM-KeyId               UUID of the public key uploaded to ABM
      ABM-PrivateKey          EC P-256 private key, PEM (ENCRYPTED variable)
      ClientId                Graph app registration (application) ID
      TenantId                Entra tenant ID
      Certificate_thumbprint  Certificate thumbprint for Graph authentication

.PARAMETER SerialNumbers
    One or more serial numbers, comma separated.

.PARAMETER MdmServerId
    ABM MDM server to unassign from. Resolved automatically when omitted, but
    only if the organisation has exactly one MDM server.

.PARAMETER DepTokenId
    Restricts the Intune DEP sync to a single enrollment token. When omitted all
    tokens are synced, which is what the original runbook did.

.PARAMETER RequestId
    Correlation identifier supplied by the dispatcher.

.PARAMETER Scenario
    Retirement | Sale | Disposal | LostStolen. Defaults to Disposal.

.PARAMETER DryRun
    'true' to resolve and log everything without unassigning or wiping.

.PARAMETER SyncWaitMinutes
    Upper bound on the wait for the DEP sync to complete before the wipe.
#>

param(
    [Parameter(Mandatory = $true)]
    [string] $SerialNumbers,

    [Parameter(Mandatory = $false)]
    [string] $MdmServerId = "",

    [Parameter(Mandatory = $false)]
    [string] $DepTokenId = "",

    [Parameter(Mandatory = $false)]
    [string] $RequestId = "",

    [Parameter(Mandatory = $false)]
    [ValidateSet("Retirement", "Sale", "Disposal", "LostStolen")]
    [string] $Scenario = "Disposal",

    # Automation passes job parameters as strings; a [bool] would bind "false"
    # to $true because any non-empty string is truthy. Parsed explicitly below.
    [Parameter(Mandatory = $false)]
    [string] $DryRun = "false",

    [Parameter(Mandatory = $false)]
    [int] $SyncWaitMinutes = 20
)

$ErrorActionPreference = "Stop"

# ============================================================
# 0. Helpers
# ============================================================

function ConvertTo-RunbookBool {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value.Trim().ToLowerInvariant() -in @('true', '1', 'yes')
}

# Secrets live in encrypted Automation variables, never in job parameters.
function Get-RequiredAutomationVariable {
    param([Parameter(Mandatory = $true)] [string] $Name)

    $value = Get-AutomationVariable -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        throw "Automation variable '$Name' is missing or empty. Create it in the Automation Account (encrypted) before running this runbook."
    }
    return $value
}

# App-only Microsoft Graph authentication.
#
# Order of preference: (1) certificate from the Automation Certificate asset,
# (2) certificate already present in the sandbox store (by thumbprint),
# (3) client secret from an encrypted Automation variable, used only as a last
# resort when no certificate is available.
#
# In Azure Automation the reliable way to use a certificate is to upload it as
# an Automation Certificate asset and retrieve the X509Certificate2 (with its
# private key) via Get-AutomationCertificate, then pass it to Connect-MgGraph
# with -Certificate. Relying on -CertificateThumbprint alone fails because the
# sandbox certificate store does not contain the asset. The asset name defaults
# to 'GraphAppCert' and can be overridden with the 'GraphCertificateName'
# Automation variable. The 'Certificate_thumbprint' variable, when present, is
# used to validate the loaded certificate (and as a store-based fallback).
function Connect-GraphAppOnly {
    param(
        [Parameter(Mandatory = $true)] [string] $ClientId,
        [Parameter(Mandatory = $true)] [string] $TenantId
    )

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $certName = Get-AutomationVariable -Name 'GraphCertificateName' -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace([string]$certName)) { $certName = 'GraphAppCert' }

    $cert = $null
    try { $cert = Get-AutomationCertificate -Name $certName -ErrorAction SilentlyContinue } catch { $cert = $null }

    $expectedThumbprint = Get-AutomationVariable -Name 'Certificate_thumbprint' -ErrorAction SilentlyContinue
    $expectedThumbprint = ([string]$expectedThumbprint).Trim().Replace(' ', '')

    if ($cert) {
        if (-not [string]::IsNullOrWhiteSpace($expectedThumbprint) -and $cert.Thumbprint -ne $expectedThumbprint) {
            Write-Warning "[Graph] Loaded certificate thumbprint $($cert.Thumbprint) does not match the Certificate_thumbprint variable ($expectedThumbprint)."
        }
        Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -Certificate $cert -NoWelcome -ErrorAction Stop
        return
    }

    # Fallback 1: a certificate already present in the runbook certificate
    # store, referenced only by thumbprint.
    if (-not [string]::IsNullOrWhiteSpace($expectedThumbprint)) {
        try {
            Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -CertificateThumbprint $expectedThumbprint -NoWelcome -ErrorAction Stop
            return
        }
        catch {
            Write-Warning "[Graph] Certificate thumbprint authentication failed: $($_.Exception.Message). Trying client-secret fallback."
        }
    }

    # Fallback 2: client secret (app-only) from the encrypted 'ClientSecret'
    # Automation variable. Certificate authentication is preferred; the secret
    # is used only when no certificate is available.
    $clientSecret = Get-AutomationVariable -Name 'ClientSecret' -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace([string]$clientSecret)) {
        Write-Warning "[Graph] No certificate available: falling back to client-secret authentication."
        $secure = ConvertTo-SecureString ([string]$clientSecret) -AsPlainText -Force
        $cred = [System.Management.Automation.PSCredential]::new($ClientId, $secure)
        Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $cred -NoWelcome -ErrorAction Stop
        return
    }

    throw "No Graph credentials available: create the Automation Certificate asset '$certName' (recommended), or set 'Certificate_thumbprint' (certificate present in the store), or set the encrypted 'ClientSecret' variable."
}

# --- Application Insights audit (optional) ---------------------------------
# See RBK-WindowsDisposal for the rationale: runbooks POST customEvents straight
# to the App Insights ingestion endpoint so their actions land in the same
# resource as the API/worker. Connection string comes from the
# 'AppInsightsConnectionString' Automation variable; absent = telemetry skipped.
$script:AiConfig = $null
$script:AiResolved = $false

function Get-RunbookAiConfig {
    if ($script:AiResolved) { return $script:AiConfig }
    $script:AiResolved = $true
    try {
        $conn = Get-AutomationVariable -Name 'AppInsightsConnectionString' -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace([string]$conn)) { return $null }
        $map = @{}
        foreach ($part in ([string]$conn).Split(';')) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            $kv = $part.Split('=', 2)
            if ($kv.Count -eq 2) { $map[$kv[0].Trim()] = $kv[1].Trim() }
        }
        if (-not $map.ContainsKey('InstrumentationKey')) { return $null }
        $endpoint = if ($map.ContainsKey('IngestionEndpoint')) { $map['IngestionEndpoint'] } else { 'https://dc.services.visualstudio.com/' }
        if (-not $endpoint.EndsWith('/')) { $endpoint += '/' }
        $script:AiConfig = @{ InstrumentationKey = $map['InstrumentationKey']; TrackUri = "${endpoint}v2/track" }
    }
    catch { $script:AiConfig = $null }
    return $script:AiConfig
}

function Send-RunbookAudit {
    param(
        [Parameter(Mandatory = $true)] [string] $Action,
        [hashtable] $Properties,
        [ValidateSet('Information', 'Warning', 'Error')] [string] $Level = 'Information'
    )
    try {
        $cfg = Get-RunbookAiConfig
        if (-not $cfg) { return }
        $props = @{ auditAction = $Action; runbook = 'RBK-AppleDisposal'; platform = 'Apple'; requestId = [string]$RequestId; scenario = [string]$Scenario }
        if ($Properties) {
            foreach ($k in $Properties.Keys) {
                if ($null -ne $Properties[$k] -and "$($Properties[$k])" -ne '') { $props[$k] = "$($Properties[$k])" }
            }
        }
        $envelope = @{
            name = 'Microsoft.ApplicationInsights.Event'
            time = (Get-Date).ToUniversalTime().ToString('o')
            iKey = $cfg.InstrumentationKey
            tags = @{ 'ai.cloud.role' = 'RBK-AppleDisposal'; 'ai.operation.id' = [string]$RequestId }
            data = @{ baseType = 'EventData'; baseData = @{ ver = 2; name = $Action; properties = $props } }
        }
        Invoke-RestMethod -Uri $cfg.TrackUri -Method POST -ContentType 'application/json' `
            -Body ($envelope | ConvertTo-Json -Depth 10 -Compress) -TimeoutSec 10 | Out-Null
    }
    catch { Write-Warning "AI audit '$Action' failed: $($_.Exception.Message)" }
}

function Write-RunbookResult {
    param([Parameter(Mandatory = $true)] $Result)
    Write-Output ("##RESULT## " + ($Result | ConvertTo-Json -Depth 10 -Compress))
}

function ConvertTo-Base64Url {
    param([byte[]] $Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertTo-Base64UrlFromString {
    param([string] $Text)
    return ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertTo-ODataStringLiteral {
    param([Parameter(Mandatory = $true)] [string] $Value)
    return $Value.Replace("'", "''")
}

# Reads the response body of a failed web request on both PowerShell 5.1 and 7+.
function Get-WebErrorBody {
    param([Parameter(Mandatory = $true)] $ErrorRecord)

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }

    $response = $ErrorRecord.Exception.Response
    if (-not $response) { return $null }

    try {
        $stream = $response.GetResponseStream()
        if (-not $stream) { return $null }
        $reader = New-Object System.IO.StreamReader($stream)
        try { return $reader.ReadToEnd() } finally { $reader.Close() }
    }
    catch {
        return "Unable to read the response stream: $($_.Exception.Message)"
    }
}

# ============================================================
# 1. ABM authentication (OAuth 2.0, JWT client assertion, ES256)
# ============================================================

function New-AbmClientAssertion {
    param(
        [Parameter(Mandatory = $true)] [string] $ClientId,
        [Parameter(Mandatory = $true)] [string] $KeyId,
        [Parameter(Mandatory = $true)] [string] $PrivateKeyPem,
        [Parameter(Mandatory = $true)] [string] $Audience
    )

    $now = [DateTimeOffset]::UtcNow
    $header = @{ alg = "ES256"; kid = $KeyId } | ConvertTo-Json -Compress
    $payload = @{
        iss = $ClientId   # teamId equals clientId for the Apple Business API
        sub = $ClientId
        aud = $Audience
        iat = $now.ToUnixTimeSeconds()
        exp = $now.AddMinutes(10).ToUnixTimeSeconds()  # short-lived: it is only used once
        jti = [Guid]::NewGuid().ToString()
    } | ConvertTo-Json -Compress

    $signingInput = "$(ConvertTo-Base64UrlFromString -Text $header).$(ConvertTo-Base64UrlFromString -Text $payload)"

    $cleanPem = $PrivateKeyPem -replace "-----BEGIN.*?-----", "" -replace "-----END.*?-----", "" -replace "\s+", ""
    $keyBytes = [Convert]::FromBase64String($cleanPem)

    # CngKey import keeps this working on the PowerShell 5.1 sandbox as well.
    $ecdsa = $null
    foreach ($blobFormat in @('Pkcs8PrivateBlob', 'EccPrivateBlob')) {
        try {
            $cngKey = [System.Security.Cryptography.CngKey]::Import(
                $keyBytes, [System.Security.Cryptography.CngKeyBlobFormat]::$blobFormat)
            $ecdsa = New-Object System.Security.Cryptography.ECDsaCng($cngKey)
            Write-Warning "[JWT] Private key imported as $blobFormat"
            break
        }
        catch {
            Write-Warning "[JWT] $blobFormat import failed: $($_.Exception.Message)"
        }
    }

    if (-not $ecdsa) {
        throw "[JWT] Unable to import the ABM private key. Check the ABM-PrivateKey variable (EC P-256, PEM)."
    }

    try {
        $signature = $ecdsa.SignData(
            [System.Text.Encoding]::UTF8.GetBytes($signingInput),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    }
    finally {
        $ecdsa.Dispose()
    }

    return "$signingInput.$(ConvertTo-Base64Url -Bytes $signature)"
}

function Get-AbmAccessToken {
    param(
        [Parameter(Mandatory = $true)] [string] $ClientId,
        [Parameter(Mandatory = $true)] [string] $KeyId,
        [Parameter(Mandatory = $true)] [string] $PrivateKeyPem
    )

    $tokenEndpoint = "https://account.apple.com/auth/oauth2/token"
    $audience = "https://account.apple.com/auth/oauth2/v2/token"

    $assertion = New-AbmClientAssertion -ClientId $ClientId -KeyId $KeyId `
        -PrivateKeyPem $PrivateKeyPem -Audience $audience

    Write-Warning "[Token] POST $tokenEndpoint"

    try {
        $response = Invoke-RestMethod -Uri $tokenEndpoint -Method POST `
            -ContentType "application/x-www-form-urlencoded" `
            -Body @{
                grant_type            = "client_credentials"
                client_id             = $ClientId
                client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
                client_assertion      = $assertion
                scope                 = "business.api"
            } -ErrorAction Stop

        Write-Warning "[Token] Obtained, expires in $($response.expires_in)s"
        return $response.access_token
    }
    catch {
        Write-Warning "[Token] Response body: $(Get-WebErrorBody -ErrorRecord $_)"
        throw "[Token] Unable to obtain the ABM access token: $($_.Exception.Message)"
    }
}

function Invoke-AbmApi {
    param(
        [Parameter(Mandatory = $true)] [string] $AccessToken,
        [Parameter(Mandatory = $true)] [string] $Url,
        [string] $Method = "GET",
        [object] $Body = $null
    )

    # FIXED: the original sent the literal string '******' here, so every call
    # was rejected with 401.
    $invokeParams = @{
        Uri         = $Url
        Method      = $Method
        Headers     = @{ Authorization = "Bearer $AccessToken"; Accept = "application/json" }
        ContentType = "application/json"
        ErrorAction = "Stop"
    }

    if ($Body) {
        $invokeParams["Body"] = $Body | ConvertTo-Json -Depth 10
    }

    Write-Warning "[ABM] $Method $Url"

    try {
        return Invoke-RestMethod @invokeParams
    }
    catch {
        Write-Warning "[ABM] Response body: $(Get-WebErrorBody -ErrorRecord $_)"
        throw
    }
}

# Polls an orgDeviceActivity until it leaves the in-progress state.
function Wait-AbmActivity {
    param(
        [Parameter(Mandatory = $true)] [string] $AccessToken,
        [Parameter(Mandatory = $true)] [string] $ApiBase,
        [Parameter(Mandatory = $true)] [string] $ActivityId,
        [int] $TimeoutSeconds = 300,
        [int] $PollSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        try {
            $activity = Invoke-AbmApi -AccessToken $AccessToken -Method "GET" `
                -Url "$ApiBase/orgDeviceActivities/$ActivityId"

            $status = [string]$activity.data.attributes.status
            $subStatus = [string]$activity.data.attributes.subStatus
            Write-Warning "[Unassign] Activity $ActivityId status=$status subStatus=$subStatus"

            if ($status -and $status -notin @('IN_PROGRESS', 'PENDING', 'ACCEPTED')) {
                return [pscustomobject]@{ Status = $status; SubStatus = $subStatus; TimedOut = $false }
            }
        }
        catch {
            Write-Warning "[Unassign] Activity poll failed: $($_.Exception.Message)"
        }
    }

    Write-Warning "[Unassign] Activity $ActivityId did not reach a terminal status within $TimeoutSeconds seconds."
    return [pscustomobject]@{ Status = 'UNKNOWN'; SubStatus = ''; TimedOut = $true }
}

# ============================================================
# 2. Intune DEP sync
# ============================================================

function Get-DepOnboardingSetting {
    param([string] $TokenId = "")

    if (-not [string]::IsNullOrWhiteSpace($TokenId)) {
        return @(Invoke-MgGraphRequest -Method GET -ErrorAction Stop `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$TokenId")
    }

    $response = Invoke-MgGraphRequest -Method GET -ErrorAction Stop `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings"
    return @($response.value)
}

# The original slept for a fixed 15 minutes. Instead, request the sync and wait
# for lastSuccessfulSyncDateTime to actually move past the request time. That is
# an observable condition, so the wait is as short as the tenant allows.
function Wait-DepSync {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Tokens,
        [Parameter(Mandatory = $true)] [datetime] $RequestedAtUtc,
        [int] $TimeoutMinutes = 20,
        [int] $PollSeconds = 30
    )

    $deadline = (Get-Date).ToUniversalTime().AddMinutes($TimeoutMinutes)
    $pending = @($Tokens | ForEach-Object { [string]$_.id })

    while ($pending.Count -gt 0 -and (Get-Date).ToUniversalTime() -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds

        $stillPending = @()
        foreach ($tokenId in $pending) {
            try {
                $token = Invoke-MgGraphRequest -Method GET -ErrorAction Stop `
                    -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$tokenId"

                $lastSync = $null
                if ($token.lastSuccessfulSyncDateTime) {
                    $lastSync = ([datetime]$token.lastSuccessfulSyncDateTime).ToUniversalTime()
                }

                if ($lastSync -and $lastSync -gt $RequestedAtUtc) {
                    Write-Warning "[Sync] Token '$($token.tokenName)' synced at $($lastSync.ToString('o'))"
                }
                else {
                    $stillPending += $tokenId
                }
            }
            catch {
                Write-Warning "[Sync] Poll failed for token '$tokenId': $($_.Exception.Message)"
                $stillPending += $tokenId
            }
        }

        $pending = $stillPending
        if ($pending.Count -gt 0) {
            Write-Warning "[Sync] $($pending.Count) token(s) still pending..."
        }
    }

    if ($pending.Count -gt 0) {
        Write-Warning "[Sync] Timed out after $TimeoutMinutes minutes; proceeding with the wipe anyway."
        return $false
    }

    Write-Warning "[Sync] All DEP tokens synced."
    return $true
}

# ============================================================
# 3. MAIN
# ============================================================

$isDryRun = ConvertTo-RunbookBool -Value $DryRun
# Retirement and LostStolen keep the ABM assignment: the device stays in the
# corporate estate and must be able to re-enroll.
$removeFromAbm = $Scenario -in @('Sale', 'Disposal')

$result = [ordered]@{
    requestId    = $RequestId
    platform     = 'Apple'
    scenario     = $Scenario
    dryRun       = $isDryRun
    wipeIssued   = $false
    unassigned   = $false
    mdmServerId  = ''
    activityId   = ''
    depSynced    = $false
    devices      = @()
    errors       = @()
    startedAt    = (Get-Date).ToUniversalTime().ToString('o')
    completedAt  = $null
}

Write-Warning "=========================================="
Write-Warning "Apple disposal - RequestId=$RequestId Scenario=$Scenario DryRun=$isDryRun"
Write-Warning "Unassign from ABM: $removeFromAbm"
Write-Warning "=========================================="

$serials = @($SerialNumbers -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -Unique)

if ($serials.Count -eq 0) {
    $result.errors += "No serial number provided."
    $result.completedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-RunbookResult -Result $result
    throw "[Main] No serial number provided in -SerialNumbers."
}

Write-Warning "[Main] Serials ($($serials.Count)): $($serials -join ', ')"
Send-RunbookAudit -Action 'RunbookStarted' -Properties @{ dryRun = $isDryRun; serialCount = $serials.Count; removeFromAbm = $removeFromAbm }

$deviceResults = [ordered]@{}
foreach ($serial in $serials) {
    $deviceResults[$serial] = [ordered]@{
        serialNumber    = $serial
        unassigned      = $false
        managedDeviceId = $null
        deviceName      = $null
        wipeIssued      = $false
        message         = ''
    }
}

$apiBase = "https://api-business.apple.com/v1"
$syncRequestedAt = $null
$syncedTokens = @()

# --- Step 1: ABM unassign ---------------------------------------------------
if ($removeFromAbm) {
    Write-Warning "=========================================="
    Write-Warning "[Main] Step 1: unassign devices in Apple Business Manager"
    Write-Warning "=========================================="

    # The whole ABM stage is best-effort: an ABM outage must not prevent the
    # wipe, and it must never abort the runbook before the ##RESULT## line is
    # emitted (the dispatcher parses that line to build the ServiceNow evidence).
    try {
        $abmClientId  = Get-RequiredAutomationVariable -Name 'ABM-ClientId'
        $abmKeyId     = Get-RequiredAutomationVariable -Name 'ABM-KeyId'
        $abmPrivatePem = Get-RequiredAutomationVariable -Name 'ABM-PrivateKey'

        Write-Warning "[Config] ABM ClientId=$abmClientId KeyId=$abmKeyId"

        $accessToken = Get-AbmAccessToken -ClientId $abmClientId -KeyId $abmKeyId -PrivateKeyPem $abmPrivatePem

        # Resolve the MDM server. Picking data[0] blindly, as the original did, is
        # only safe when there is exactly one server.
        if ([string]::IsNullOrWhiteSpace($MdmServerId)) {
            $mdmServers = Invoke-AbmApi -AccessToken $accessToken -Method "GET" -Url "$apiBase/mdmServers"
            $servers = @($mdmServers.data)

            foreach ($server in $servers) {
                Write-Warning "[ABM] MDM server: Id=$($server.id) Name=$($server.attributes.name)"
            }

            if ($servers.Count -eq 1) {
                $MdmServerId = $servers[0].id
                Write-Warning "[ABM] Single MDM server found, using '$MdmServerId'"
            }
            elseif ($servers.Count -eq 0) {
                throw "[ABM] No MDM server returned by Apple Business Manager."
            }
            else {
                throw "[ABM] $($servers.Count) MDM servers found. Pass -MdmServerId explicitly to avoid unassigning from the wrong one."
            }
        }

        $result.mdmServerId = $MdmServerId
        Write-Warning "[ABM] MDM server: $MdmServerId"

        if ($isDryRun) {
            Write-Warning "[ABM] DRY RUN: skipping the UNASSIGN_DEVICES activity"
            $result.unassigned = $true
            foreach ($serial in $serials) { $deviceResults[$serial].unassigned = $true }
        }
        else {
            $unassignBody = @{
                data = @{
                    type          = "orgDeviceActivities"
                    attributes    = @{ activityType = "UNASSIGN_DEVICES" }
                    relationships = @{
                        devices   = @{ data = @($serials | ForEach-Object { @{ type = "orgDevices"; id = $_ } }) }
                        mdmServer = @{ data = @{ type = "mdmServers"; id = $MdmServerId } }
                    }
                }
            }

            $activity = Invoke-AbmApi -AccessToken $accessToken -Method "POST" `
                -Url "$apiBase/orgDeviceActivities" -Body $unassignBody

            $activityId = [string]$activity.data.id
            $result.activityId = $activityId
            Write-Warning "[Unassign] Activity $activityId created, status=$($activity.data.attributes.status)"

            # FIXED: the original never checked the outcome of the activity.
            $final = Wait-AbmActivity -AccessToken $accessToken -ApiBase $apiBase -ActivityId $activityId

            if ($final.Status -eq 'COMPLETED') {
                $result.unassigned = $true
                foreach ($serial in $serials) {
                    $deviceResults[$serial].unassigned = $true
                    $deviceResults[$serial].message = 'Unassigned in ABM'
                }
            }
            else {
                $result.errors += "ABM unassign activity $activityId ended with status '$($final.Status)' / '$($final.SubStatus)'."
                Write-Warning "[Unassign] Activity did not complete successfully; the wipe will still be attempted."
            }
        }
    }
    catch {
        $result.errors += "ABM unassign failed: $($_.Exception.Message)"
        Write-Warning "[Unassign] Failed: $($_.Exception.Message)"
        Write-Warning "[Unassign] The wipe will still be attempted."
    }
}
else {
    Write-Warning "[Main] Step 1 skipped: scenario '$Scenario' keeps the ABM assignment."
}

# --- Step 2: Graph ----------------------------------------------------------
Write-Warning "=========================================="
Write-Warning "[Main] Step 2: connect to Microsoft Graph"
Write-Warning "=========================================="

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$graphClientId   = Get-RequiredAutomationVariable -Name 'ClientId'
$graphTenantId   = Get-RequiredAutomationVariable -Name 'TenantId'

try {
    Connect-GraphAppOnly -ClientId $graphClientId -TenantId $graphTenantId
    Write-Warning "[Graph] Connected"
    Send-RunbookAudit -Action 'GraphConnected'
}
catch {
    $result.errors += "Graph connection failed: $($_.Exception.Message)"
    $result.completedAt = (Get-Date).ToUniversalTime().ToString('o')
    Send-RunbookAudit -Action 'GraphConnectFailed' -Level 'Error' -Properties @{ error = $_.Exception.Message }
    Write-RunbookResult -Result $result
    throw
}

try {
    # --- Step 3: DEP sync ---------------------------------------------------
    if ($removeFromAbm -and -not $isDryRun) {
        Write-Warning "=========================================="
        Write-Warning "[Main] Step 3: sync the Intune DEP tokens"
        Write-Warning "=========================================="

        try {
            $tokens = @(Get-DepOnboardingSetting -TokenId $DepTokenId)

            if ($tokens.Count -eq 0) {
                Write-Warning "[Sync] No DEP enrollment token found."
                $result.errors += "No DEP enrollment token found in Intune."
            }
            else {
                $syncRequestedAt = (Get-Date).ToUniversalTime()

                foreach ($token in $tokens) {
                    Write-Warning "[Sync] Token '$($token.tokenName)' ($($token.id)) last sync $($token.lastSuccessfulSyncDateTime)"
                    try {
                        Invoke-MgGraphRequest -Method POST -ErrorAction Stop `
                            -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$($token.id)/syncWithAppleDeviceEnrollmentProgram" | Out-Null
                        $syncedTokens += $token
                        Write-Warning "[Sync] Sync requested for '$($token.tokenName)'"
                    }
                    catch {
                        # Intune throttles this call to once every 15 minutes;
                        # a rejection is not fatal, the previous sync may do.
                        Write-Warning "[Sync] Sync request rejected for '$($token.tokenName)': $($_.Exception.Message)"
                        $result.errors += "DEP sync request failed for token '$($token.tokenName)': $($_.Exception.Message)"
                    }
                }

                if ($syncedTokens.Count -gt 0) {
                    $result.depSynced = Wait-DepSync -Tokens $syncedTokens `
                        -RequestedAtUtc $syncRequestedAt -TimeoutMinutes $SyncWaitMinutes
                }
            }
        }
        catch {
            Write-Warning "[Sync] DEP token enumeration failed: $($_.Exception.Message)"
            $result.errors += "DEP token enumeration failed: $($_.Exception.Message)"
        }
    }

    # --- Step 4: wipe -------------------------------------------------------
    Write-Warning "=========================================="
    Write-Warning "[Main] Step 4: wipe devices in Intune"
    Write-Warning "=========================================="

    foreach ($serial in $serials) {
        $escapedSerial = ConvertTo-ODataStringLiteral -Value $serial

        try {
            $deviceResponse = Invoke-MgGraphRequest -Method GET -ErrorAction Stop `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=serialNumber eq '$escapedSerial'"
            $devices = @($deviceResponse.value)
        }
        catch {
            Write-Warning "[Wipe] Lookup failed for '$serial': $($_.Exception.Message)"
            $result.errors += "Intune lookup failed for serial '$serial': $($_.Exception.Message)"
            $deviceResults[$serial].message = 'Intune lookup failed'
            continue
        }

        if ($devices.Count -eq 0) {
            Write-Warning "[Wipe] No Intune managed device found for '$serial'"
            $result.errors += "No Intune managed device found for serial '$serial'."
            $deviceResults[$serial].message = 'No Intune managed device found'
            continue
        }

        foreach ($device in $devices) {
            $deviceResults[$serial].managedDeviceId = $device.id
            $deviceResults[$serial].deviceName = $device.deviceName

            Write-Warning "[Wipe] Device: $($device.deviceName) (Id=$($device.id), OS=$($device.operatingSystem) $($device.osVersion))"

            if ($isDryRun) {
                Write-Warning "[Wipe] DRY RUN: skipping wipe for '$($device.deviceName)'"
                $deviceResults[$serial].wipeIssued = $true
                $deviceResults[$serial].message = 'Dry run'
                $result.wipeIssued = $true
                continue
            }

            try {
                Invoke-MgGraphRequest -Method POST -ErrorAction Stop `
                    -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($device.id)/wipe" `
                    -Body (@{ keepEnrollmentData = $false; keepUserData = $false } | ConvertTo-Json) `
                    -ContentType "application/json" | Out-Null

                Write-Warning "[Wipe] Wipe command sent for '$($device.deviceName)'"
                $deviceResults[$serial].wipeIssued = $true
                $deviceResults[$serial].message = 'Wipe command sent'
                $result.wipeIssued = $true
                Send-RunbookAudit -Action 'DeviceWipeIssued' -Properties @{ serialNumber = $serial; deviceName = $device.deviceName; managedDeviceId = $device.id; dryRun = $isDryRun }
            }
            catch {
                Write-Warning "[Wipe] Wipe failed for '$($device.deviceName)': $($_.Exception.Message)"
                $result.errors += "Wipe failed for serial '$serial': $($_.Exception.Message)"
                $deviceResults[$serial].message = 'Wipe failed'
                Send-RunbookAudit -Action 'DeviceWipeFailed' -Level 'Error' -Properties @{ serialNumber = $serial; deviceName = $device.deviceName; managedDeviceId = $device.id; error = $_.Exception.Message }
            }
        }
    }
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

# ============================================================
# 4. Outcome
# ============================================================

$result.devices = @($serials | ForEach-Object { [pscustomobject]$deviceResults[$_] })
$result.completedAt = (Get-Date).ToUniversalTime().ToString('o')

Write-Warning "=========================================="
Write-Warning "[Main] Summary"
Write-Warning "=========================================="
foreach ($item in $result.devices) {
    Write-Warning "[Summary] Serial=$($item.serialNumber) Unassigned=$($item.unassigned) Device=$($item.deviceName) WipeIssued=$($item.wipeIssued) - $($item.message)"
}

Write-RunbookResult -Result $result
Send-RunbookAudit -Action 'RunbookCompleted' -Level ($(if ($result.wipeIssued) { 'Information' } else { 'Error' })) -Properties @{ wipeIssued = $result.wipeIssued; deviceCount = @($result.devices).Count; errorCount = @($result.errors).Count; status = ($(if ($result.wipeIssued -and @($result.errors).Count -eq 0) { 'Completed' } elseif ($result.wipeIssued) { 'PartiallyCompleted' } else { 'Failed' })) }

if (-not $result.wipeIssued) {
    throw "[Main] No wipe command could be issued for any of the requested serials."
}

Write-Warning "[Main] Completed."
