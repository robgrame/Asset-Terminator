# Graph.psm1
# Self-contained Microsoft Graph helpers for the single-function wipe mock.
#
# Authentication: OAuth2 *client credentials* using an app registration + client
# secret (GRAPH_TENANT_ID / GRAPH_CLIENT_ID / GRAPH_CLIENT_SECRET). No managed
# identity and no certificate are used. The token is cached in-process until a
# minute before it expires.
#
# ALL configuration comes from the Function App Application Settings (environment
# variables). Every knob has a safe default so the mock runs with only the three
# GRAPH_* credential settings populated. Configurable settings:
#   GRAPH_TENANT_ID, GRAPH_CLIENT_ID, GRAPH_CLIENT_SECRET   (credentials, required)
#   GRAPH_BASE_URI            (default https://graph.microsoft.com/beta)
#   GRAPH_AUTHORITY_HOST      (default https://login.microsoftonline.com)
#   GRAPH_SCOPE              (default https://graph.microsoft.com/.default)
#   GRAPH_MAX_RETRIES         (default 4)
#   WIPE_KEEP_ENROLLMENT_DATA (default false)
#   WIPE_KEEP_USER_DATA       (default false)

$script:TokenCache = $null   # @{ AccessToken = ...; ExpiresOn = [datetime] }

function Get-AppSetting {
    <#
        .SYNOPSIS
            Reads a Function Application Setting (environment variable), returning
            $Default when it is unset or empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [string] $Default
    )
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function Get-AppSettingBool {
    <#
        .SYNOPSIS
            Reads a boolean Function Application Setting, returning $Default when
            unset or not parseable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [bool] $Default = $false
    )
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    try { return [System.Convert]::ToBoolean($value) } catch { return $Default }
}

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

    if ($script:TokenCache -and $script:TokenCache.ExpiresOn -gt (Get-Date).AddMinutes(1)) {
        return $script:TokenCache.AccessToken
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

    $script:TokenCache = @{
        AccessToken = $response.access_token
        ExpiresOn   = (Get-Date).AddSeconds([int]$response.expires_in)
    }
    return $script:TokenCache.AccessToken
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

Export-ModuleMember -Function Write-MockLog, ConvertTo-DeviceOs, Get-GraphToken, Invoke-GraphRequest, `
    Get-IntuneManagedDevice, Remove-AutopilotDevice, Invoke-IntuneWipe, Get-DeviceWipeStatus, `
    Get-AutopilotDeviceStatus, Get-AppSetting, Get-AppSettingBool
