#Requires -Version 7.4
<#
.SYNOPSIS
    Windows Autopilot removal + Intune wipe. Corrected version for the
    Service Bus dispatch pipeline.

.DESCRIPTION
    Corrections and changes vs the original Windows_Disposal_Device.ps1:

      * FIXED: three occurrences of ':IsNullOrWhiteSpace(...)' instead of
        '[string]::IsNullOrWhiteSpace(...)'. The original does not parse, so the
        webhook branch could never run.
      * FIXED: assignment to '$matches', a PowerShell automatic variable
        populated by -match. Renamed to '$autopilotMatches'.
      * REMOVED: the -WebhookData branch. The dispatcher starts the runbook with
        named parameters through ARM, so webhooks (and their tokens in the URL)
        are no longer used.
      * ADDED: -RequestId, -Scenario and -DryRun so the runbook honours the
        business scenario and can be exercised safely.
      * ADDED: the '##RESULT## {json}' structured output line consumed by the
        JobMonitor function to build the ServiceNow evidence.
      * ADDED: the runbook now fails (terminating error) when no wipe could be
        issued, so the job status itself is meaningful.

    Scenario semantics:
      Retirement  wipe only, the device stays in Autopilot (asset is reused)
      Sale        remove from Autopilot, then wipe
      Disposal    remove from Autopilot, then wipe
      LostStolen  wipe only, the device stays registered for tracking

    CREDENTIALS
    All credentials are read from encrypted Azure Automation variables. Nothing
    secret is ever accepted as a runbook parameter: job parameters are stored in
    clear text in the job metadata and are visible to any Job Reader.

      ClientId                Graph app registration (application) ID
      TenantId                Entra tenant ID
      Certificate_thumbprint  Thumbprint of the certificate in the Automation
                              Account certificate store

    Required Graph application permissions:
      DeviceManagementServiceConfig.ReadWrite.All
      DeviceManagementManagedDevices.Read.All
      DeviceManagementManagedDevices.PrivilegedOperations.All

.PARAMETER SerialNumbers
    One or more serial numbers, comma separated.

.PARAMETER RequestId
    Correlation identifier supplied by the dispatcher (the ServiceNow request).

.PARAMETER Scenario
    Retirement | Sale | Disposal | LostStolen. Defaults to Disposal.

.PARAMETER DryRun
    'true' to resolve and log everything without deleting or wiping anything.

.PARAMETER WipeWaitSeconds
    Delay between the Autopilot delete and the wipe, to let the deletion settle.

.EXAMPLE
    .\RBK-WindowsDisposal.ps1 -SerialNumbers "ABC123,DEF456" -Scenario Disposal
#>

param(
    [Parameter(Mandatory = $true)]
    [string] $SerialNumbers,

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
    [int] $WipeWaitSeconds = 60
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
# A missing variable must fail loudly instead of producing a confusing 401.
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
# Runbooks run in Azure Automation, outside the Functions host, so their only
# native trace is the job stream. To land every action in the same App Insights
# resource as the API/worker we POST customEvents directly to the ingestion
# endpoint. The connection string comes from the 'AppInsightsConnectionString'
# Automation variable; if it is absent telemetry is silently skipped.
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
        $props = @{ auditAction = $Action; runbook = 'RBK-WindowsDisposal'; platform = 'Windows'; requestId = [string]$RequestId; scenario = [string]$Scenario }
        if ($Properties) {
            foreach ($k in $Properties.Keys) {
                if ($null -ne $Properties[$k] -and "$($Properties[$k])" -ne '') { $props[$k] = "$($Properties[$k])" }
            }
        }
        $envelope = @{
            name = 'Microsoft.ApplicationInsights.Event'
            time = (Get-Date).ToUniversalTime().ToString('o')
            iKey = $cfg.InstrumentationKey
            tags = @{ 'ai.cloud.role' = 'RBK-WindowsDisposal'; 'ai.operation.id' = [string]$RequestId }
            data = @{ baseType = 'EventData'; baseData = @{ ver = 2; name = $Action; properties = $props } }
        }
        Invoke-RestMethod -Uri $cfg.TrackUri -Method POST -ContentType 'application/json' `
            -Body ($envelope | ConvertTo-Json -Depth 10 -Compress) -TimeoutSec 10 | Out-Null
    }
    catch { Write-Warning "AI audit '$Action' failed: $($_.Exception.Message)" }
}

# The dispatcher's JobMonitor parses this single line out of the job output.
# Everything else in the stream is human-readable diagnostics.
function Write-RunbookResult {
    param([Parameter(Mandatory = $true)] $Result)
    Write-Output ("##RESULT## " + ($Result | ConvertTo-Json -Depth 10 -Compress))
}

function ConvertTo-ODataStringLiteral {
    param([Parameter(Mandatory = $true)] [string] $Value)
    # OData single quote escaping: ' becomes ''
    return $Value.Replace("'", "''")
}

function Invoke-GraphRequestSafe {
    param(
        [Parameter(Mandatory = $true)] [string] $Uri,
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "POST", "DELETE", "PATCH", "PUT")]
        [string] $Method,
        [object] $Body = $null,
        [string] $ContentType = "application/json"
    )

    $params = @{
        Uri         = $Uri
        Method      = $Method
        ErrorAction = "Stop"
    }

    if ($null -ne $Body) {
        $params["Body"] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
        $params["ContentType"] = $ContentType
    }

    Write-Verbose "[Graph] $Method $Uri"
    return Invoke-MgGraphRequest @params
}

function Get-GraphPagedResult {
    param([Parameter(Mandatory = $true)] [string] $Uri)

    $allItems = @()
    $nextUri = $Uri

    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        $response = Invoke-GraphRequestSafe -Uri $nextUri -Method "GET"
        if ($null -ne $response.value) { $allItems += $response.value }

        if ($response.PSObject.Properties.Name -contains "@odata.nextLink") {
            $nextUri = $response.'@odata.nextLink'
        }
        else {
            $nextUri = $null
        }
    }

    return $allItems
}

# ============================================================
# 1. Autopilot
# ============================================================

function Find-AutopilotDeviceBySerial {
    param([Parameter(Mandatory = $true)] [string] $SerialNumber)

    $escapedSerial = ConvertTo-ODataStringLiteral -Value $SerialNumber
    # 'contains' tolerates service-side formatting differences on the serial.
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$escapedSerial')&`$top=25"

    Write-Warning "[Autopilot] Searching Autopilot identity for serial '$SerialNumber'"

    try {
        $response = Invoke-GraphRequestSafe -Uri $uri -Method "GET"
        $candidates = @($response.value)
        $exactMatches = @($candidates | Where-Object { $_.serialNumber -eq $SerialNumber })

        if ($exactMatches.Count -gt 0) { return $exactMatches }

        foreach ($candidate in $candidates) {
            Write-Warning "[Autopilot] Non-exact candidate: ID=$($candidate.id), Serial=$($candidate.serialNumber)"
        }
        return @()
    }
    catch {
        Write-Warning "[Autopilot] Filtered search failed for '$SerialNumber': $($_.Exception.Message)"
        Write-Warning "[Autopilot] Falling back to a paged full-list search"

        $fallbackUri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$top=100"
        $allAutopilotDevices = Get-GraphPagedResult -Uri $fallbackUri
        return @($allAutopilotDevices | Where-Object { $_.serialNumber -eq $SerialNumber })
    }
}

function Remove-AutopilotDevice {
    param(
        [Parameter(Mandatory = $true)] [object] $AutopilotDevice,
        [bool] $WhatIfMode = $false
    )

    $autopilotId = $AutopilotDevice.id
    $serial = $AutopilotDevice.serialNumber

    # FIXED: was ':IsNullOrWhiteSpace($autopilotId)'
    if ([string]::IsNullOrWhiteSpace($autopilotId)) {
        throw "[Autopilot] Autopilot device ID is empty for serial '$serial'"
    }

    Write-Warning "[Autopilot] Device found: ID=$autopilotId, Serial=$serial, DisplayName=$($AutopilotDevice.displayName), ManagedDeviceId=$($AutopilotDevice.managedDeviceId)"

    if ($WhatIfMode) {
        Write-Warning "[Autopilot] DRY RUN: skipping DELETE for AutopilotId=$autopilotId"
        return $true
    }

    try {
        Invoke-GraphRequestSafe -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$autopilotId" -Method "DELETE" | Out-Null
        Write-Warning "[Autopilot] Deleted: Serial=$serial, AutopilotId=$autopilotId"
        return $true
    }
    catch {
        Write-Warning "[Autopilot] Delete failed for Serial=${serial}: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================
# 2. Intune
# ============================================================

function Find-ManagedDeviceBySerial {
    param([Parameter(Mandatory = $true)] [string] $SerialNumber)

    $escapedSerial = ConvertTo-ODataStringLiteral -Value $SerialNumber
    Write-Warning "[Wipe] Searching Intune managed device for serial '$SerialNumber'"

    try {
        $response = Invoke-GraphRequestSafe -Method "GET" `
            -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$escapedSerial'"
        return @($response.value)
    }
    catch {
        Write-Warning "[Wipe] Search failed for serial '$SerialNumber': $($_.Exception.Message)"
        return @()
    }
}

function Invoke-ManagedDeviceWipe {
    param(
        [Parameter(Mandatory = $true)] [object] $ManagedDevice,
        [bool] $KeepEnrollmentData = $false,
        [bool] $KeepUserData = $false,
        [bool] $WhatIfMode = $false
    )

    $deviceId = $ManagedDevice.id
    $deviceName = $ManagedDevice.deviceName

    if ([string]::IsNullOrWhiteSpace($deviceId)) {
        throw "[Wipe] ManagedDeviceId is empty for serial '$($ManagedDevice.serialNumber)'"
    }

    Write-Warning "[Wipe] Managed device: Name=$deviceName, Id=$deviceId, Serial=$($ManagedDevice.serialNumber), OS=$($ManagedDevice.operatingSystem) $($ManagedDevice.osVersion), UPN=$($ManagedDevice.userPrincipalName)"

    if ($WhatIfMode) {
        Write-Warning "[Wipe] DRY RUN: skipping wipe for '$deviceName'"
        return $true
    }

    try {
        Invoke-GraphRequestSafe `
            -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$deviceId/wipe" `
            -Method "POST" `
            -Body @{ keepEnrollmentData = $KeepEnrollmentData; keepUserData = $KeepUserData } | Out-Null

        Write-Warning "[Wipe] Wipe command sent for '$deviceName' (Id=$deviceId)"
        return $true
    }
    catch {
        Write-Warning "[Wipe] Wipe failed for '$deviceName': $($_.Exception.Message)"
        return $false
    }
}

# ============================================================
# 3. MAIN
# ============================================================

$isDryRun = ConvertTo-RunbookBool -Value $DryRun
# Retirement and LostStolen keep the Autopilot registration: the hardware stays
# in the corporate estate and must be able to re-enroll.
$removeFromAutopilot = $Scenario -in @('Sale', 'Disposal')

$result = [ordered]@{
    requestId   = $RequestId
    platform    = 'Windows'
    scenario    = $Scenario
    dryRun      = $isDryRun
    wipeIssued  = $false
    devices     = @()
    errors      = @()
    startedAt   = (Get-Date).ToUniversalTime().ToString('o')
    completedAt = $null
}

Write-Warning "=========================================="
Write-Warning "Windows disposal - RequestId=$RequestId Scenario=$Scenario DryRun=$isDryRun"
Write-Warning "Remove from Autopilot: $removeFromAutopilot"
Write-Warning "=========================================="

$serials = @($SerialNumbers -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -Unique)

if ($serials.Count -eq 0) {
    $result.errors += "No serial number provided."
    $result.completedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-RunbookResult -Result $result
    throw "[Main] No serial number provided in -SerialNumbers."
}

Write-Warning "[Main] Serials ($($serials.Count)): $($serials -join ', ')"
Send-RunbookAudit -Action 'RunbookStarted' -Properties @{ dryRun = $isDryRun; serialCount = $serials.Count; removeFromAutopilot = $removeFromAutopilot }

# --- Connect to Graph -------------------------------------------------------
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$graphClientId   = Get-RequiredAutomationVariable -Name 'ClientId'
$graphTenantId   = Get-RequiredAutomationVariable -Name 'TenantId'

Write-Warning "[Graph] ClientId=$graphClientId TenantId=$graphTenantId"

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
    $deviceResults = [ordered]@{}
    foreach ($serial in $serials) {
        $deviceResults[$serial] = [ordered]@{
            serialNumber     = $serial
            autopilotFound   = $false
            autopilotDeleted = $false
            autopilotId      = $null
            managedDeviceId  = $null
            deviceName       = $null
            wipeIssued       = $false
            message          = ''
        }
    }

    # --- Step 1: Autopilot --------------------------------------------------
    if ($removeFromAutopilot) {
        Write-Warning "=========================================="
        Write-Warning "[Main] Step 1: remove devices from Windows Autopilot"
        Write-Warning "=========================================="

        foreach ($serial in $serials) {
            # FIXED: was '$matches', a PowerShell automatic variable.
            $autopilotMatches = @(Find-AutopilotDeviceBySerial -SerialNumber $serial)

            if ($autopilotMatches.Count -eq 0) {
                Write-Warning "[Autopilot] No Autopilot identity found for '$serial'"
                $deviceResults[$serial].message = 'No Autopilot identity found'
                continue
            }

            $deviceResults[$serial].autopilotFound = $true
            $deviceResults[$serial].autopilotId = $autopilotMatches[0].id

            $allDeleted = $true
            foreach ($autopilotDevice in $autopilotMatches) {
                if (-not (Remove-AutopilotDevice -AutopilotDevice $autopilotDevice -WhatIfMode $isDryRun)) {
                    $allDeleted = $false
                    $result.errors += "Autopilot delete failed for serial '$serial' (id $($autopilotDevice.id))."
                }
            }
            $deviceResults[$serial].autopilotDeleted = $allDeleted
        }
    }
    else {
        Write-Warning "[Main] Step 1 skipped: scenario '$Scenario' keeps the Autopilot registration."
    }

    # --- Step 2: settle -----------------------------------------------------
    if ($removeFromAutopilot -and -not $isDryRun -and $WipeWaitSeconds -gt 0) {
        Write-Warning "[Main] Step 2: waiting $WipeWaitSeconds seconds before the wipe"
        Start-Sleep -Seconds $WipeWaitSeconds
    }

    # --- Step 3: wipe -------------------------------------------------------
    Write-Warning "=========================================="
    Write-Warning "[Main] Step 3: wipe devices in Intune"
    Write-Warning "=========================================="

    foreach ($serial in $serials) {
        $managedDevices = @(Find-ManagedDeviceBySerial -SerialNumber $serial)

        if ($managedDevices.Count -eq 0) {
            Write-Warning "[Wipe] No Intune managed device found for '$serial'"
            $result.errors += "No Intune managed device found for serial '$serial'."
            $deviceResults[$serial].message = 'No Intune managed device found'
            continue
        }

        foreach ($managedDevice in $managedDevices) {
            $wipeSent = Invoke-ManagedDeviceWipe -ManagedDevice $managedDevice -WhatIfMode $isDryRun

            $deviceResults[$serial].managedDeviceId = $managedDevice.id
            $deviceResults[$serial].deviceName = $managedDevice.deviceName
            $deviceResults[$serial].wipeIssued = $wipeSent

            if ($wipeSent) {
                $result.wipeIssued = $true
                $deviceResults[$serial].message = 'Wipe command sent'
                Send-RunbookAudit -Action 'DeviceWipeIssued' -Properties @{ serialNumber = $serial; deviceName = $managedDevice.deviceName; managedDeviceId = $managedDevice.id; dryRun = $isDryRun }
            }
            else {
                $result.errors += "Wipe failed for serial '$serial' (device $($managedDevice.deviceName))."
                $deviceResults[$serial].message = 'Wipe failed'
                Send-RunbookAudit -Action 'DeviceWipeFailed' -Level 'Error' -Properties @{ serialNumber = $serial; deviceName = $managedDevice.deviceName; managedDeviceId = $managedDevice.id }
            }
        }
    }

    $result.devices = @($serials | ForEach-Object { [pscustomobject]$deviceResults[$_] })
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

# ============================================================
# 4. Outcome
# ============================================================

$result.completedAt = (Get-Date).ToUniversalTime().ToString('o')

Write-Warning "=========================================="
Write-Warning "[Main] Summary"
Write-Warning "=========================================="
foreach ($item in $result.devices) {
    Write-Warning "[Summary] Serial=$($item.serialNumber) AutopilotFound=$($item.autopilotFound) AutopilotDeleted=$($item.autopilotDeleted) Device=$($item.deviceName) WipeIssued=$($item.wipeIssued) - $($item.message)"
}

Write-RunbookResult -Result $result
Send-RunbookAudit -Action 'RunbookCompleted' -Level ($(if ($result.wipeIssued) { 'Information' } else { 'Error' })) -Properties @{ wipeIssued = $result.wipeIssued; deviceCount = @($result.devices).Count; errorCount = @($result.errors).Count; status = ($(if ($result.wipeIssued -and @($result.errors).Count -eq 0) { 'Completed' } elseif ($result.wipeIssued) { 'PartiallyCompleted' } else { 'Failed' })) }

# The job status must reflect the business outcome: a runbook that wiped nothing
# is a failure, not a success with warnings.
if (-not $result.wipeIssued) {
    throw "[Main] No wipe command could be issued for any of the requested serials."
}

Write-Warning "[Main] Completed."
