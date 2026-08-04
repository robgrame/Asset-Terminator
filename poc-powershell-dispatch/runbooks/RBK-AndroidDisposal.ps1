#Requires -Version 7.6
<#
.SYNOPSIS
    Samsung Knox Mobile Enrollment removal + Intune wipe. Corrected version for
    direct dispatch from the Function App.

.DESCRIPTION
    Corrections and changes vs the original ITA_SAMSUNG_KME_Device_Disposal.ps1:

      * REMOVED: the runbook only accepted $WebhookData and threw immediately
        without it, so it could not be started through ARM with named
        parameters. It now takes -Serials and is dispatched like the others,
        which also removes the webhook token from the caller's URL.
      * FIXED: 'Escape-ODataString' used an unapproved, non-existent verb.
        Renamed to ConvertTo-ODataStringLiteral.
      * FIXED: the KME delete outcome was only written to the output stream and
        never influenced the result. failedDeviceList entries are now real
        errors and drive the returned status.
      * FIXED: the Intune wipe errors were swallowed with Write-Error inside a
        loop while the runbook still ended as Completed.
      * FIXED: the JWT 'iat' was computed with Get-Date -UFormat %s, which is
        locale and platform dependent. Replaced with DateTimeOffset.
      * ADDED: -RequestId, -Scenario and -DryRun.
      * ADDED: the '##RESULT## {json}' structured output line.
      * ADDED: RSA key is disposed, and the KME region is a parameter.

    Scenario semantics:
      Retirement  wipe only, the device stays enrolled in KME
      Sale        remove from KME, then wipe
      Disposal    remove from KME, then wipe
      LostStolen  wipe only, the device stays enrolled for tracking

    CREDENTIALS
    All credentials are read from encrypted Azure Automation variables. Nothing
    secret is ever accepted as a runbook parameter: job parameters are stored in
    clear text in the job metadata and are visible to any Job Reader.

      KME-ClientIdentifier    Client Identifier from the Knox API Portal
      KME-KeysJson            Keys JSON downloaded from the Knox API Portal
                              (ENCRYPTED variable: it contains the private key)
      KME-CustomerId          Knox customer ID
      ClientId                Graph app registration (application) ID
      TenantId                Entra tenant ID
      Certificate_thumbprint  Certificate thumbprint for Graph authentication

.PARAMETER Serials
    One or more serial numbers or IMEIs, comma separated.

.PARAMETER RequestId
    Correlation identifier supplied by the dispatcher.

.PARAMETER Scenario
    Retirement | Sale | Disposal | LostStolen. Defaults to Disposal.

.PARAMETER DryRun
    'true' to resolve and log everything without deleting or wiping.

.PARAMETER KmeRegion
    'eu' or 'us'. Selects the Knox Cloud Services endpoint.
#>

param(
    [Parameter(Mandatory = $true)]
    [string] $Serials,

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
    [ValidateSet("eu", "us")]
    [string] $KmeRegion = "eu"
)

$ErrorActionPreference = "Stop"

$KmeBaseUrls = @{
    "us" = "https://us-kcs-api.samsungknox.com"
    "eu" = "https://eu-kcs-api.samsungknox.com"
}
$KmeBaseUrl = $KmeBaseUrls[$KmeRegion]

# ==============================================================================
# 0. Helpers
# ==============================================================================

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
# resource as the Function App. Connection string comes from the
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
        $props = @{ auditAction = $Action; runbook = 'RBK-AndroidDisposal'; platform = 'Android'; requestId = [string]$RequestId; scenario = [string]$Scenario }
        if ($Properties) {
            foreach ($k in $Properties.Keys) {
                if ($null -ne $Properties[$k] -and "$($Properties[$k])" -ne '') { $props[$k] = "$($Properties[$k])" }
            }
        }
        $envelope = @{
            name = 'Microsoft.ApplicationInsights.Event'
            time = (Get-Date).ToUniversalTime().ToString('o')
            iKey = $cfg.InstrumentationKey
            tags = @{ 'ai.cloud.role' = 'RBK-AndroidDisposal'; 'ai.operation.id' = [string]$RequestId }
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

function Write-KmeLog {
    param([string] $Section, [string] $Message)
    Write-Warning "[$Section] $Message"
}

function ConvertTo-Base64Url {
    param([byte[]] $Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertTo-Base64UrlFromString {
    param([string] $Text)
    return ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Text))
}

# FIXED: was 'Escape-ODataString'. 'Escape' is not an approved PowerShell verb
# and the function name triggered a warning on module import.
function ConvertTo-ODataStringLiteral {
    param([Parameter(Mandatory = $true)] [string] $Value)
    return $Value.Replace("'", "''")
}

function New-KnoxJwt {
    param(
        [Parameter(Mandatory = $true)] [hashtable] $PayloadClaims,
        [Parameter(Mandatory = $true)] [System.Security.Cryptography.RSA] $RsaKey
    )

    $header = '{"alg":"RS512","typ":"JWT"}'
    $headerB64 = ConvertTo-Base64UrlFromString -Text $header

    # FIXED: the original used (Get-Date -UFormat %s), which is locale and
    # platform dependent and can emit a fractional value.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $claims = $PayloadClaims.Clone()
    $claims["iat"] = $now
    $claims["exp"] = $now + 1800   # 30 minutes
    $claims["aud"] = "KnoxWSM"
    $claims["jti"] = [guid]::NewGuid().ToString() + [guid]::NewGuid().ToString()

    $payloadB64 = ConvertTo-Base64UrlFromString -Text ($claims | ConvertTo-Json -Compress)

    $signature = $RsaKey.SignData(
        [System.Text.Encoding]::UTF8.GetBytes("$headerB64.$payloadB64"),
        [System.Security.Cryptography.HashAlgorithmName]::SHA512,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

    return "$headerB64.$payloadB64.$(ConvertTo-Base64Url -Bytes $signature)"
}

# ==============================================================================
# 1. MAIN - input
# ==============================================================================

$isDryRun = ConvertTo-RunbookBool -Value $DryRun
# Retirement and LostStolen keep the KME enrollment: the device stays in the
# corporate estate and must be able to re-enroll.
$removeFromKme = $Scenario -in @('Sale', 'Disposal')

$result = [ordered]@{
    requestId   = $RequestId
    platform    = 'Android'
    scenario    = $Scenario
    dryRun      = $isDryRun
    wipeIssued  = $false
    devices     = @()
    errors      = @()
    startedAt   = (Get-Date).ToUniversalTime().ToString('o')
    completedAt = $null
}

Write-Warning "=========================================="
Write-Warning "Samsung KME disposal - RequestId=$RequestId Scenario=$Scenario DryRun=$isDryRun"
Write-Warning "Remove from KME: $removeFromKme  Region: $KmeRegion"
Write-Warning "=========================================="

$serialsToProcess = @($Serials -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -Unique)

if ($serialsToProcess.Count -eq 0) {
    $result.errors += "No serial number provided."
    $result.completedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-RunbookResult -Result $result
    throw "[Main] No serial number provided in -Serials."
}

Write-Warning "[Main] Serials/IMEIs ($($serialsToProcess.Count)): $($serialsToProcess -join ', ')"
Send-RunbookAudit -Action 'RunbookStarted' -Properties @{ dryRun = $isDryRun; serialCount = $serialsToProcess.Count }

$deviceResults = [ordered]@{}
foreach ($serial in $serialsToProcess) {
    $deviceResults[$serial] = [ordered]@{
        identifier      = $serial
        matchedBy       = $null
        kmeRemoved      = $false
        managedDeviceId = $null
        deviceName      = $null
        wipeIssued      = $false
        message         = ''
    }
}

# ==============================================================================
# 2. Samsung Knox removal
# ==============================================================================

if ($removeFromKme) {
    Write-Warning "=========================================="
    Write-Warning "[Main] Step 1: authenticate to Samsung Knox"
    Write-Warning "=========================================="

    $rsaKey = $null
    $signedAccessToken = $null
    try {
        $kmeClientIdentifier = Get-RequiredAutomationVariable -Name 'KME-ClientIdentifier'
        $kmeKeysJsonStr      = Get-RequiredAutomationVariable -Name 'KME-KeysJson'
        $kmeCustomerId       = Get-RequiredAutomationVariable -Name 'KME-CustomerId'

        $kmeKeys = $kmeKeysJsonStr | ConvertFrom-Json
        $privateKeyBase64 = $kmeKeys.Private
        $publicKeyBase64  = $kmeKeys.Public

        if ([string]::IsNullOrWhiteSpace($privateKeyBase64) -or [string]::IsNullOrWhiteSpace($publicKeyBase64)) {
            throw "KME-KeysJson does not contain both a 'Private' and a 'Public' key."
        }

        Write-KmeLog "Knox" "Keys loaded. Identifier: $($kmeKeys.Identifier)"

        # PKCS#8 DER -> CngKey -> RSACng, compatible with the PowerShell 5.1 sandbox.
        $cngKey = [System.Security.Cryptography.CngKey]::Import(
            [Convert]::FromBase64String($privateKeyBase64),
            [System.Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
        $rsaKey = New-Object System.Security.Cryptography.RSACng($cngKey)

        Write-KmeLog "Knox" "RSA key imported (KeySize: $($rsaKey.KeySize) bit)"

        # Step 1a: sign the client identifier
        $clientIdentifierJwt = New-KnoxJwt -RsaKey $rsaKey -PayloadClaims @{
            clientIdentifier = $kmeClientIdentifier
            publicKey        = $publicKeyBase64
        }

        # Step 1b: request the access token
        $tokenResponse = Invoke-RestMethod -Uri "$KmeBaseUrl/ams/v1/users/accesstoken" `
            -Method Post -ContentType "application/json" -ErrorAction Stop `
            -Body (@{
                clientIdentifierJwt             = $clientIdentifierJwt
                base64EncodedStringPublicKey    = $publicKeyBase64
                validityForAccessTokenInMinutes = 30
            } | ConvertTo-Json -Depth 5)

        $rawAccessToken = $tokenResponse.accessToken
        if (-not $rawAccessToken) {
            throw "No accessToken in the Knox response."
        }

        # Step 1c: sign the access token
        $signedAccessToken = New-KnoxJwt -RsaKey $rsaKey -PayloadClaims @{
            accessToken = $rawAccessToken
            publicKey   = $publicKeyBase64
        }

        Write-KmeLog "Knox" "Knox API token ready"
    }
    catch {
        if ($rsaKey) { $rsaKey.Dispose(); $rsaKey = $null }
        # Best-effort, like the ABM stage in the Apple runbook: a Knox outage
        # must not prevent the Intune wipe, which is the safety-critical action.
        $result.errors += "Knox authentication failed: $($_.Exception.Message)"
        Write-KmeLog "Knox" "Authentication failed: $($_.Exception.Message)"
        Write-KmeLog "Knox" "Steps 1-2 skipped; the wipe will still be attempted."
        $signedAccessToken = $null
    }

    if ($signedAccessToken) {
    Write-Warning "=========================================="
    Write-Warning "[Main] Step 2: remove devices from KME"
    Write-Warning "=========================================="

    try {
        foreach ($serialNumber in $serialsToProcess) {
            if ($isDryRun) {
                Write-KmeLog "KME" "DRY RUN: skipping delete for '$serialNumber'"
                $deviceResults[$serialNumber].kmeRemoved = $true
                $deviceResults[$serialNumber].message = 'Dry run'
                continue
            }

            try {
                Write-KmeLog "KME" "Removing device: $serialNumber"

                # Built step by step: PS 5.1 mishandles deeply nested inline hashtables.
                $devices = @{}
                $devices["imeiOrSerials"] = @($serialNumber)

                $deleteBody = @{}
                $deleteBody["customerId"] = $kmeCustomerId
                $deleteBody["devices"] = $devices

                $deleteResponse = Invoke-RestMethod -Uri "$KmeBaseUrl/kcs/v1/kme/devices/delete" `
                    -Method Post -ContentType "application/json" -ErrorAction Stop `
                    -Headers @{ "x-knox-apitoken" = $signedAccessToken } `
                    -Body ($deleteBody | ConvertTo-Json -Depth 5)

                $successList  = @($deleteResponse.successDeviceList)
                $failedList   = @($deleteResponse.failedDeviceList)
                $notFoundList = @($deleteResponse.notFoundDeviceList)

                if ($successList.Count -gt 0) {
                    Write-KmeLog "KME" "Removed: $($successList -join ', ')"
                    $deviceResults[$serialNumber].kmeRemoved = $true
                    $deviceResults[$serialNumber].message = 'Removed from KME'
                }

                if ($notFoundList.Count -gt 0) {
                    # Not an error: the device may already have been removed.
                    Write-KmeLog "KME" "Not found in KME (already removed?): $($notFoundList -join ', ')"
                    $deviceResults[$serialNumber].message = 'Not found in KME'
                }

                # FIXED: failures used to be logged and then ignored.
                if ($failedList.Count -gt 0) {
                    Write-KmeLog "KME" "Removal FAILED for: $($failedList -join ', ')"
                    $result.errors += "KME removal failed for '$serialNumber'."
                    $deviceResults[$serialNumber].message = 'KME removal failed'
                }
            }
            catch {
                Write-KmeLog "KME" "Error removing '$serialNumber': $($_.Exception.Message)"
                $result.errors += "KME removal error for '$serialNumber': $($_.Exception.Message)"
                $deviceResults[$serialNumber].message = 'KME removal error'
            }
        }
    }
    finally {
        if ($rsaKey) { $rsaKey.Dispose() }
    }
    }
}
else {
    Write-Warning "[Main] Steps 1-2 skipped: scenario '$Scenario' keeps the KME enrollment."
}

# ==============================================================================
# 3. Intune wipe
# ==============================================================================

Write-Warning "=========================================="
Write-Warning "[Main] Step 3: wipe devices in Intune"
Write-Warning "=========================================="

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$graphClientId   = Get-RequiredAutomationVariable -Name 'ClientId'
$graphTenantId   = Get-RequiredAutomationVariable -Name 'TenantId'

try {
    Connect-GraphAppOnly -ClientId $graphClientId -TenantId $graphTenantId
    Write-KmeLog "Intune" "Connected to Graph"
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
    foreach ($serialNumber in $serialsToProcess) {
        try {
            # A 15-digit value is an IMEI, anything else is a serial number.
            $isImei = $serialNumber -match '^\d{15}$'
            $escaped = ConvertTo-ODataStringLiteral -Value $serialNumber

            if ($isImei) {
                $filterQuery = "imei eq '$escaped'"
                $deviceResults[$serialNumber].matchedBy = 'imei'
            }
            else {
                $filterQuery = "serialNumber eq '$escaped'"
                $deviceResults[$serialNumber].matchedBy = 'serialNumber'
            }

            Write-KmeLog "Intune" "Searching device by $($deviceResults[$serialNumber].matchedBy): $serialNumber"

            $deviceResult = Invoke-MgGraphRequest -Method GET -ErrorAction Stop `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=$filterQuery"
            $devices = @($deviceResult.value)

            if ($devices.Count -eq 0) {
                Write-KmeLog "Intune" "Device not found: $serialNumber"
                $result.errors += "No Intune managed device found for '$serialNumber'."
                $deviceResults[$serialNumber].message = 'No Intune managed device found'
                continue
            }

            foreach ($managedDevice in $devices) {
                $deviceResults[$serialNumber].managedDeviceId = $managedDevice.id
                $deviceResults[$serialNumber].deviceName = $managedDevice.deviceName

                Write-KmeLog "Intune" "Device: $($managedDevice.deviceName) (Id=$($managedDevice.id))"

                if ($isDryRun) {
                    Write-KmeLog "Intune" "DRY RUN: skipping wipe for '$($managedDevice.deviceName)'"
                    $deviceResults[$serialNumber].wipeIssued = $true
                    $result.wipeIssued = $true
                    continue
                }

                try {
                    Invoke-MgGraphRequest -Method POST -ErrorAction Stop `
                        -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($managedDevice.id)/wipe" `
                        -Body (@{ keepEnrollmentData = $false; keepUserData = $false } | ConvertTo-Json) `
                        -ContentType "application/json" | Out-Null

                    Write-KmeLog "Intune" "Wipe command sent for '$($managedDevice.deviceName)'"
                    $deviceResults[$serialNumber].wipeIssued = $true
                    $deviceResults[$serialNumber].message = 'Wipe command sent'
                    $result.wipeIssued = $true
                    Send-RunbookAudit -Action 'DeviceWipeIssued' -Properties @{ serialNumber = $serialNumber; deviceName = $managedDevice.deviceName; managedDeviceId = $managedDevice.id; dryRun = $isDryRun }
                }
                catch {
                    # FIXED: this used to be a Write-Error that left the job Completed.
                    Write-KmeLog "Intune" "Wipe failed for '$($managedDevice.deviceName)': $($_.Exception.Message)"
                    $result.errors += "Wipe failed for '$serialNumber': $($_.Exception.Message)"
                    $deviceResults[$serialNumber].message = 'Wipe failed'
                    Send-RunbookAudit -Action 'DeviceWipeFailed' -Level 'Error' -Properties @{ serialNumber = $serialNumber; deviceName = $managedDevice.deviceName; managedDeviceId = $managedDevice.id; error = $_.Exception.Message }
                }
            }
        }
        catch {
            Write-KmeLog "Intune" "Error processing '$serialNumber': $($_.Exception.Message)"
            $result.errors += "Intune error for '$serialNumber': $($_.Exception.Message)"
            $deviceResults[$serialNumber].message = 'Intune error'
        }
    }
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

# ==============================================================================
# 4. Outcome
# ==============================================================================

$result.devices = @($serialsToProcess | ForEach-Object { [pscustomobject]$deviceResults[$_] })
$result.completedAt = (Get-Date).ToUniversalTime().ToString('o')

Write-Warning "=========================================="
Write-Warning "[Main] Summary"
Write-Warning "=========================================="
foreach ($item in $result.devices) {
    Write-Warning "[Summary] Id=$($item.identifier) MatchedBy=$($item.matchedBy) KmeRemoved=$($item.kmeRemoved) Device=$($item.deviceName) WipeIssued=$($item.wipeIssued) - $($item.message)"
}

Write-RunbookResult -Result $result
Send-RunbookAudit -Action 'RunbookCompleted' -Level ($(if ($result.wipeIssued) { 'Information' } else { 'Error' })) -Properties @{ wipeIssued = $result.wipeIssued; deviceCount = @($result.devices).Count; errorCount = @($result.errors).Count; status = ($(if ($result.wipeIssued -and @($result.errors).Count -eq 0) { 'Completed' } elseif ($result.wipeIssued) { 'PartiallyCompleted' } else { 'Failed' })) }

if (-not $result.wipeIssued) {
    throw "[Main] No wipe command could be issued for any of the requested identifiers."
}

Write-Warning "[Main] Completed."
