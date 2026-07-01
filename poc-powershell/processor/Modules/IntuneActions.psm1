# IntuneActions.psm1
# Microsoft Graph helpers for the decommission actions the POC adds on top of the
# plain wipe: deleting the device from Windows Autopilot (a pre-wipe step of the
# Terminate disposition) and issuing the Intune retire action (the Retire
# disposition). Both honour DryRun so nothing destructive happens by default.
#
# Mirrors AutopilotDeleteProvider and IntuneRetireProvider of the full .NET
# solution (src/AssetTerminator.Providers.Intune).

function Remove-AutopilotDevice {
    <#
        .SYNOPSIS
            Removes a device from Windows Autopilot by serial number.
        .DESCRIPTION
            Resolves the windowsAutopilotDeviceIdentities object by serialNumber
            and deletes it. This is a Terminate pre-wipe step so a re-imaged /
            re-purposed device is no longer bound to the tenant's Autopilot
            profile. Requires DeviceManagementServiceConfig.ReadWrite.All.
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
        Write-PocLog -Level 'Warning' -Message 'Autopilot delete skipped: no serialNumber supplied.' -Properties $LogProperties
        return [pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'Skipped'; Detail = 'No serialNumber.' }
    }

    if ($DryRun) {
        Write-PocLog -Level 'Information' -Message "DRY-RUN: Autopilot delete skipped for serial $SerialNumber." -Properties $LogProperties
        return [pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'DryRun'; Detail = "Would delete Autopilot identity for serial $SerialNumber." }
    }

    $escaped = $SerialNumber.Replace("'", "''")
    $filter = [Uri]::EscapeDataString("contains(serialNumber,'$escaped')")
    $result = Invoke-GraphRequest -Method GET -Path "deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$filter"
    $identity = @($result.value) | Where-Object { $_.serialNumber -eq $SerialNumber } | Select-Object -First 1
    if (-not $identity) {
        # Fall back to the first contains() match when there is no exact hit.
        $identity = @($result.value) | Select-Object -First 1
    }

    if (-not $identity) {
        Write-PocLog -Level 'Information' -Message "No Autopilot identity found for serial $SerialNumber; nothing to delete." -Properties $LogProperties
        return [pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'NotFound'; Detail = "No Autopilot identity for serial $SerialNumber." }
    }

    Invoke-GraphRequest -Method DELETE -Path "deviceManagement/windowsAutopilotDeviceIdentities/$($identity.id)" | Out-Null
    Write-PocLog -Level 'Information' -Message "Deleted Autopilot identity $($identity.id) for serial $SerialNumber." -Properties $LogProperties
    return [pscustomobject]@{ Action = 'AutopilotDelete'; Outcome = 'Deleted'; Detail = "Deleted Autopilot identity $($identity.id)." }
}

function Invoke-IntuneRetire {
    <#
        .SYNOPSIS
            Issues the Intune managedDevice retire action (or simulates it in DryRun).
        .DESCRIPTION
            POST /deviceManagement/managedDevices/{id}/retire removes company data
            and unenrolls the device without wiping it -- the re-purpose path of the
            Retire disposition. Uses DeviceManagementManagedDevices.PrivilegedOperations.All.
        .OUTPUTS
            PSCustomObject: Action, Outcome (DryRun|Issued), ExecutedAt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ManagedDeviceId,
        [switch] $DryRun,
        [hashtable] $LogProperties = @{}
    )

    if ($DryRun) {
        Write-PocLog -Level 'Information' -Message "DRY-RUN: retire skipped for managedDevice $ManagedDeviceId." -Properties $LogProperties
        return [pscustomobject]@{
            ManagedDeviceId = $ManagedDeviceId
            Action          = 'Retire'
            Outcome         = 'DryRun'
            ExecutedAt      = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    Invoke-GraphRequest -Method POST -Path "deviceManagement/managedDevices/$ManagedDeviceId/retire" | Out-Null
    Write-PocLog -Level 'Information' -Message "Retire command issued for managedDevice $ManagedDeviceId." -Properties $LogProperties
    return [pscustomobject]@{
        ManagedDeviceId = $ManagedDeviceId
        Action          = 'Retire'
        Outcome         = 'Issued'
        ExecutedAt      = (Get-Date).ToUniversalTime().ToString('o')
    }
}

Export-ModuleMember -Function Remove-AutopilotDevice, Invoke-IntuneRetire
