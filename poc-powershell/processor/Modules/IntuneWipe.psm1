# IntuneWipe.psm1
# Microsoft Graph helpers to look up an Intune managed device and to issue the
# wipe action. Supports a DryRun mode that evaluates everything but does NOT
# perform the destructive call.

function Select-FreshestManagedDevice {
    <#
        .SYNOPSIS
            Given multiple managedDevice candidates that match the same lookup
            criteria, returns the "freshest" object: the one with the most recent
            enrollment date and, as a tie-breaker, the most recent check-in
            (lastSyncDateTime). Null/missing dates sort as the oldest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Devices
    )

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
            Resolves an Intune managed device by managedDeviceId, or by the
            combination of deviceName and/or serialNumber.
        .DESCRIPTION
            ServiceNow sends the serial number together with the device name.
            Several stale objects can share the same name/serial (re-enrollment,
            hardware re-imaging, etc.), so when more than one candidate matches we
            do NOT pick an arbitrary one: we select the freshest device by
            enrolledDateTime, then by lastSyncDateTime (see
            Select-FreshestManagedDevice).
        .OUTPUTS
            The managedDevice Graph object, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [string] $ManagedDeviceId,
        [string] $DeviceName,
        [string] $SerialNumber,
        [hashtable] $LogProperties = @{}
    )

    $select = 'id,deviceName,managedDeviceOwnerType,operatingSystem,osVersion,isEncrypted,complianceState,enrolledDateTime,lastSyncDateTime,userPrincipalName,serialNumber,manufacturer,deviceCategoryDisplayName'

    if ($ManagedDeviceId) {
        try {
            return Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices/$ManagedDeviceId`?`$select=$select"
        }
        catch {
            return $null
        }
    }

    if (-not $DeviceName -and -not $SerialNumber) {
        throw 'Get-IntuneManagedDevice requires -ManagedDeviceId, -DeviceName or -SerialNumber.'
    }

    # Build a server-side $filter. deviceName and serialNumber are both filterable
    # on managedDevices; combine them with 'and' when both are supplied.
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
        # serialNumber may not be filterable in every tenant; fall back to a
        # deviceName-only server filter (or an unfiltered page) and narrow locally.
        Write-PocLog -Level 'Warning' -Message "Server-side filter failed ($($_.Exception.Message)); falling back to client-side matching." -Properties $LogProperties
        if ($DeviceName) {
            $nameFilter = [Uri]::EscapeDataString("deviceName eq '$($DeviceName.Replace("'", "''"))'")
            $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$filter=$nameFilter&`$select=$select"
        }
        else {
            $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$select=$select"
        }
        $candidates = @($result.value)
    }

    # Defensive client-side narrowing in case the server ignored a clause.
    if ($DeviceName)   { $candidates = @($candidates | Where-Object { $_.deviceName   -eq $DeviceName }) }
    if ($SerialNumber) { $candidates = @($candidates | Where-Object { $_.serialNumber -eq $SerialNumber }) }

    if ($candidates.Count -eq 0) { return $null }

    if ($candidates.Count -gt 1) {
        Write-PocLog -Level 'Warning' `
            -Message "Found $($candidates.Count) managed devices matching the criteria; selecting the freshest by enrolledDateTime/lastSyncDateTime." `
            -Properties $LogProperties
    }

    return Select-FreshestManagedDevice -Devices $candidates
}

function Invoke-IntuneWipe {
    <#
        .SYNOPSIS
            Issues the Intune managedDevice wipe action (or simulates it in DryRun).
        .DESCRIPTION
            Uses POST /deviceManagement/managedDevices/{id}/wipe. The wipe payload
            is configurable for the different device types.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ManagedDeviceId,
        [switch] $DryRun,
        [bool] $KeepEnrollmentData = $false,
        [bool] $KeepUserData = $false,
        [hashtable] $LogProperties = @{}
    )

    if ($DryRun) {
        Write-PocLog -Level 'Information' -Message "DRY-RUN: wipe skipped for managedDevice $ManagedDeviceId" -Properties $LogProperties
        return [pscustomobject]@{
            ManagedDeviceId = $ManagedDeviceId
            Action          = 'Wipe'
            Outcome         = 'DryRun'
            ExecutedAt      = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    $body = @{
        keepEnrollmentData = $KeepEnrollmentData
        keepUserData       = $KeepUserData
    }

    Invoke-GraphRequest -Method POST -Path "deviceManagement/managedDevices/$ManagedDeviceId/wipe" -Body $body | Out-Null
    Write-PocLog -Level 'Information' -Message "Wipe command issued for managedDevice $ManagedDeviceId" -Properties $LogProperties

    return [pscustomobject]@{
        ManagedDeviceId = $ManagedDeviceId
        Action          = 'Wipe'
        Outcome         = 'Issued'
        ExecutedAt      = (Get-Date).ToUniversalTime().ToString('o')
    }
}

Export-ModuleMember -Function Get-IntuneManagedDevice, Invoke-IntuneWipe, Select-FreshestManagedDevice
