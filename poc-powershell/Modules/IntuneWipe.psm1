# IntuneWipe.psm1
# Microsoft Graph helpers to look up an Intune managed device and to issue the
# wipe action. Supports a DryRun mode that evaluates everything but does NOT
# perform the destructive call.

function Get-IntuneManagedDevice {
    <#
        .SYNOPSIS
            Resolves an Intune managed device by its managedDeviceId or deviceName.
        .OUTPUTS
            The managedDevice Graph object, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [string] $ManagedDeviceId,
        [string] $DeviceName
    )

    $select = 'id,deviceName,managedDeviceOwnerType,operatingSystem,osVersion,isEncrypted,complianceState,lastSyncDateTime,userPrincipalName,serialNumber,deviceCategoryDisplayName'

    if ($ManagedDeviceId) {
        try {
            return Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices/$ManagedDeviceId`?`$select=$select"
        }
        catch {
            return $null
        }
    }

    if ($DeviceName) {
        $escaped = $DeviceName.Replace("'", "''")
        $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/managedDevices?`$filter=deviceName eq '$escaped'&`$select=$select"
        return $result.value | Select-Object -First 1
    }

    throw 'Get-IntuneManagedDevice requires either -ManagedDeviceId or -DeviceName.'
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

Export-ModuleMember -Function Get-IntuneManagedDevice, Invoke-IntuneWipe
