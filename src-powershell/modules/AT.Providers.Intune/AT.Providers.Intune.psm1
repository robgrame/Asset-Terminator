# AT.Providers.Intune.psm1
# Microsoft Graph / Intune device provider. Parity with
# AssetTerminator.Providers.Intune (Wipe / Retire / Delete / Autopilot delete).
# Every destructive call honours -DryRun.

Set-StrictMode -Version Latest

$script:DeviceSelect = 'id,deviceName,managedDeviceOwnerType,operatingSystem,osVersion,isEncrypted,complianceState,enrolledDateTime,lastSyncDateTime,userPrincipalName,serialNumber,manufacturer,deviceCategoryDisplayName'

function Select-FreshestManagedDevice {
    <#
        .SYNOPSIS
            Selects the freshest managedDevice among candidates: most recent
            enrolledDateTime, then lastSyncDateTime. Null dates sort oldest.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Devices)
    $min = [datetime]::MinValue
    return $Devices |
        Sort-Object `
            @{ Expression = { if ($_.enrolledDateTime) { [datetime]$_.enrolledDateTime } else { $min } }; Descending = $true }, `
            @{ Expression = { if ($_.lastSyncDateTime) { [datetime]$_.lastSyncDateTime } else { $min } }; Descending = $true } |
        Select-Object -First 1
}

function Get-IntuneManagedDevice {
    <#
        .SYNOPSIS
            Resolves an Intune managed device by id, or by deviceName/serialNumber,
            picking the freshest when several match. Parity with GraphIntuneService.
    #>
    [CmdletBinding()]
    param(
        [string] $ManagedDeviceId,
        [string] $DeviceName,
        [string] $SerialNumber,
        [hashtable] $LogProperties = @{}
    )

    if ($ManagedDeviceId) {
        try { return Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices/$ManagedDeviceId`?`$select=$script:DeviceSelect" }
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
        $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$filter=$filter&`$select=$script:DeviceSelect"
        $candidates = @($result.value)
    }
    catch {
        Write-AtLog -Level 'Warning' -Message "Server-side filter failed ($($_.Exception.Message)); falling back to client-side matching." -Properties $LogProperties
        if ($DeviceName) {
            $nameFilter = [Uri]::EscapeDataString("deviceName eq '$($DeviceName.Replace("'", "''"))'")
            $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$filter=$nameFilter&`$select=$script:DeviceSelect"
        }
        else {
            $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$select=$script:DeviceSelect"
        }
        $candidates = @($result.value)
    }

    if ($DeviceName)   { $candidates = @($candidates | Where-Object { $_.deviceName   -eq $DeviceName }) }
    if ($SerialNumber) { $candidates = @($candidates | Where-Object { $_.serialNumber -eq $SerialNumber }) }
    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -gt 1) {
        Write-AtLog -Level 'Warning' -Message "Found $($candidates.Count) managed devices matching; selecting the freshest." -Properties $LogProperties
    }
    return Select-FreshestManagedDevice -Devices $candidates
}

function Invoke-IntuneWipe {
    <# Issues the managedDevice wipe (or simulates in DryRun). Parity with IntuneWipeProvider. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ManagedDeviceId,
        [switch] $DryRun,
        [bool] $KeepEnrollmentData = $false,
        [bool] $KeepUserData = $false,
        [hashtable] $LogProperties = @{}
    )
    if ($DryRun) {
        Write-AtLog -Message "DRY-RUN: wipe skipped for managedDevice $ManagedDeviceId" -Properties $LogProperties
        return [pscustomobject]@{ ManagedDeviceId = $ManagedDeviceId; Action = 'Wipe'; Outcome = 'DryRun'; ExecutedAt = ([datetime]::UtcNow).ToString('o') }
    }
    Invoke-GraphRequest -Method POST -Path "deviceManagement/managedDevices/$ManagedDeviceId/wipe" -Body @{ keepEnrollmentData = $KeepEnrollmentData; keepUserData = $KeepUserData } | Out-Null
    Write-AtLog -Message "Wipe command issued for managedDevice $ManagedDeviceId" -Properties $LogProperties
    return [pscustomobject]@{ ManagedDeviceId = $ManagedDeviceId; Action = 'Wipe'; Outcome = 'Issued'; ExecutedAt = ([datetime]::UtcNow).ToString('o') }
}

function Invoke-IntuneRetire {
    <# Issues the managedDevice retire (re-purpose). Parity with IntuneRetireProvider. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ManagedDeviceId, [switch] $DryRun, [hashtable] $LogProperties = @{})
    if ($DryRun) {
        Write-AtLog -Message "DRY-RUN: retire skipped for managedDevice $ManagedDeviceId." -Properties $LogProperties
        return [pscustomobject]@{ ManagedDeviceId = $ManagedDeviceId; Action = 'Retire'; Outcome = 'DryRun'; ExecutedAt = ([datetime]::UtcNow).ToString('o') }
    }
    Invoke-GraphRequest -Method POST -Path "deviceManagement/managedDevices/$ManagedDeviceId/retire" | Out-Null
    Write-AtLog -Message "Retire command issued for managedDevice $ManagedDeviceId." -Properties $LogProperties
    return [pscustomobject]@{ ManagedDeviceId = $ManagedDeviceId; Action = 'Retire'; Outcome = 'Issued'; ExecutedAt = ([datetime]::UtcNow).ToString('o') }
}

function Remove-IntuneManagedDevice {
    <# Deletes the managedDevice object. Parity with IntuneDeleteProvider. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ManagedDeviceId, [switch] $DryRun, [hashtable] $LogProperties = @{})
    if ($DryRun) {
        Write-AtLog -Message "DRY-RUN: managedDevice delete skipped for $ManagedDeviceId." -Properties $LogProperties
        return [pscustomobject]@{ ManagedDeviceId = $ManagedDeviceId; Action = 'IntuneDelete'; Outcome = 'DryRun' }
    }
    Invoke-GraphRequest -Method DELETE -Path "deviceManagement/managedDevices/$ManagedDeviceId" | Out-Null
    Write-AtLog -Message "Deleted managedDevice $ManagedDeviceId." -Properties $LogProperties
    return [pscustomobject]@{ ManagedDeviceId = $ManagedDeviceId; Action = 'IntuneDelete'; Outcome = 'Deleted' }
}

function Remove-AutopilotDevice {
    <# Deletes the Windows Autopilot registration by serial. Parity with AutopilotDeleteProvider. #>
    [CmdletBinding()]
    param([string] $SerialNumber, [switch] $DryRun, [hashtable] $LogProperties = @{})
    if (-not $SerialNumber) {
        Write-AtLog -Level 'Warning' -Message 'Autopilot delete skipped: no serialNumber supplied.' -Properties $LogProperties
        return [pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'Skipped'; Detail = 'No serialNumber.' }
    }
    if ($DryRun) {
        Write-AtLog -Message "DRY-RUN: Autopilot delete skipped for serial $SerialNumber." -Properties $LogProperties
        return [pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'DryRun'; Detail = "Would delete Autopilot identity for serial $SerialNumber." }
    }
    $escaped = $SerialNumber.Replace("'", "''")
    $filter = [Uri]::EscapeDataString("contains(serialNumber,'$escaped')")
    $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$filter"
    $identity = @($result.value) | Where-Object { $_.serialNumber -eq $SerialNumber } | Select-Object -First 1
    if (-not $identity) { $identity = @($result.value) | Select-Object -First 1 }
    if (-not $identity) {
        Write-AtLog -Message "No Autopilot identity found for serial $SerialNumber; nothing to delete." -Properties $LogProperties
        return [pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'NotFound'; Detail = "No Autopilot identity for serial $SerialNumber." }
    }
    Invoke-GraphRequest -Method DELETE -Path "deviceManagement/windowsAutopilotDeviceIdentities/$($identity.id)" | Out-Null
    Write-AtLog -Message "Deleted Autopilot identity $($identity.id) for serial $SerialNumber." -Properties $LogProperties
    return [pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'Deleted'; Detail = "Deleted Autopilot identity $($identity.id)." }
}

function Resolve-IntuneDeviceFromContext {
    <# Resolves the managedDevice for a context (by id, else name/serial), or $null. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [hashtable] $LogProperties = @{})
    $id = if ($Context.PSObject.Properties['IntuneDeviceId']) { $Context.IntuneDeviceId } else { $null }
    $name = if ($Context.PSObject.Properties['DeviceName']) { $Context.DeviceName } else { $null }
    $serial = if ($Context.PSObject.Properties['SerialNumber']) { $Context.SerialNumber } else { $null }
    if ($id) { return Get-IntuneManagedDevice -ManagedDeviceId $id -LogProperties $LogProperties }
    if ($name -or $serial) { return Get-IntuneManagedDevice -DeviceName $name -SerialNumber $serial -LogProperties $LogProperties }
    return $null
}

function Get-IntuneWipeStatus {
    <#
        .SYNOPSIS
            Re-checks live wipe status for the polling engine. Success when the wipe
            completed or the device is gone; transient Failure while pending/offline;
            hard Failure on a reported wipe failure. Parity with IntuneWipeProvider.GetWipeStatusAsync.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [hashtable] $LogProperties = @{})
    try {
        $device = Resolve-IntuneDeviceFromContext -Context $Context -LogProperties $LogProperties
        if (-not $device) { return [pscustomobject]@{ Status = 'Success'; Detail = 'not present in Intune'; Transient = $false } }

        $mgmt = if ($device.PSObject.Properties['managementState']) { [string]$device.managementState } else { '' }
        if ($mgmt -eq 'wipeFailed') { return [pscustomobject]@{ Status = 'Failed'; Detail = 'Intune wipe failed'; Transient = $false } }

        $actions = @()
        if ($device.PSObject.Properties['deviceActionResults'] -and $device.deviceActionResults) { $actions = @($device.deviceActionResults) }
        $wipe = $actions |
            Where-Object { [string]$_.actionName -ieq 'wipe' } |
            Sort-Object @{ Expression = { if ($_.lastUpdatedDateTime) { [datetime]$_.lastUpdatedDateTime } elseif ($_.startDateTime) { [datetime]$_.startDateTime } else { [datetime]::MinValue } }; Descending = $true } |
            Select-Object -First 1
        if ($wipe -and [string]$wipe.actionState -ieq 'done') {
            return [pscustomobject]@{ Status = 'Success'; Detail = 'Intune wipe completed'; Transient = $false }
        }
        return [pscustomobject]@{ Status = 'Failed'; Detail = 'wipe pending / device offline'; Transient = $true }
    }
    catch {
        $code = Get-HttpStatus -ErrorRecord $_
        if ($code -eq 404) { return [pscustomobject]@{ Status = 'Success'; Detail = 'not present in Intune'; Transient = $false } }
        $transient = ($code -eq 429 -or $code -ge 500)
        return [pscustomobject]@{ Status = 'Failed'; Detail = $_.Exception.Message; Transient = $transient }
    }
}

function Get-IntuneRetireStatus {
    <#
        .SYNOPSIS
            Re-checks live retire status: Success once the device leaves management
            (gone), otherwise transient pending. Parity with IntuneRetireProvider.GetRetireStatusAsync.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [hashtable] $LogProperties = @{})
    try {
        $device = Resolve-IntuneDeviceFromContext -Context $Context -LogProperties $LogProperties
        if (-not $device) { return [pscustomobject]@{ Status = 'Success'; Detail = 'not present in Intune'; Transient = $false } }
        return [pscustomobject]@{ Status = 'Failed'; Detail = 'retire pending / device still managed'; Transient = $true }
    }
    catch {
        $code = Get-HttpStatus -ErrorRecord $_
        if ($code -eq 404) { return [pscustomobject]@{ Status = 'Success'; Detail = 'not present in Intune'; Transient = $false } }
        $transient = ($code -eq 429 -or $code -ge 500)
        return [pscustomobject]@{ Status = 'Failed'; Detail = $_.Exception.Message; Transient = $transient }
    }
}

function Get-IntuneDeleteStatus {
    <#
        .SYNOPSIS
            Re-checks live managedDevice-delete status: Success once the object is gone,
            transient while it still exists. Parity with IntuneDeleteProvider.GetStatusAsync.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [hashtable] $LogProperties = @{})
    try {
        $device = Resolve-IntuneDeviceFromContext -Context $Context -LogProperties $LogProperties
        if (-not $device) { return [pscustomobject]@{ Status = 'Success'; Detail = 'not present in Intune'; Transient = $false } }
        return [pscustomobject]@{ Status = 'Failed'; Detail = "Intune managedDevice still present: $($device.id)"; Transient = $true }
    }
    catch {
        $code = Get-HttpStatus -ErrorRecord $_
        if ($code -eq 404) { return [pscustomobject]@{ Status = 'Success'; Detail = 'not present in Intune'; Transient = $false } }
        $transient = ($code -eq 429 -or $code -ge 500)
        return [pscustomobject]@{ Status = 'Failed'; Detail = $_.Exception.Message; Transient = $transient }
    }
}

Export-ModuleMember -Function Select-FreshestManagedDevice, Get-IntuneManagedDevice, Invoke-IntuneWipe, `
    Invoke-IntuneRetire, Remove-IntuneManagedDevice, Remove-AutopilotDevice, `
    Resolve-IntuneDeviceFromContext, Get-IntuneWipeStatus, Get-IntuneRetireStatus, Get-IntuneDeleteStatus
