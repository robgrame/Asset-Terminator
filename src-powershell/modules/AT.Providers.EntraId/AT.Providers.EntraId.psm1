# AT.Providers.EntraId.psm1
# Entra ID (Azure AD) directory device provider. Parity with
# AssetTerminator.Providers.EntraId (GraphEntraDeviceService + EntraIdDeleteProvider).
# Deletes by directory OBJECT id (Graph device id), not the deviceId registration GUID.

Set-StrictMode -Version Latest

function Resolve-EntraDeviceObjectId {
    <#
        .SYNOPSIS
            Resolves the Entra directory object id for a device context. Prefers an
            explicit EntraDeviceId, else looks up by displayName. Returns $null if unknown.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Context)

    $entraId = Get-OptionalProp $Context 'EntraDeviceId'
    if ($entraId) { return $entraId }

    $deviceName = Get-OptionalProp $Context 'DeviceName'
    if (-not $deviceName) { return $null }

    $filter = [Uri]::EscapeDataString("displayName eq '$($deviceName.Replace("'", "''"))'")
    try {
        $result = Invoke-GraphRequest -Method GET -Path "devices?`$filter=$filter&`$top=1"
        $device = @($result.value) | Select-Object -First 1
        if ($device) { return $device.id }
        return $null
    }
    catch {
        if ((Get-HttpStatus -ErrorRecord $_) -eq 404) { return $null }
        throw
    }
}

function Test-EntraDeviceExists {
    <# Returns $true when the directory object with the given id still exists. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ObjectId)
    try {
        $device = Invoke-GraphRequest -Method GET -Path "devices/$ObjectId`?`$select=id"
        return $null -ne $device
    }
    catch {
        if ((Get-HttpStatus -ErrorRecord $_) -eq 404) { return $false }
        throw
    }
}

function Remove-EntraDevice {
    <#
        .SYNOPSIS
            Deletes an Entra directory device object by OBJECT id. Honours -DryRun.
            Parity with EntraIdDeleteProvider.DeleteAsync — returns a ProviderResult.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Context,
        [switch] $DryRun,
        [hashtable] $LogProperties = @{}
    )
    try {
        $objectId = Resolve-EntraDeviceObjectId -Context $Context
        if (-not $objectId) {
            return New-ProviderResult -Status 'Skipped' -Detail 'not present in Entra ID'
        }
        if ($DryRun) {
            Write-AtLog -Message "DRY-RUN: Entra device delete skipped for object $objectId." -Properties $LogProperties
            return New-ProviderResult -Status 'Skipped' -Detail "DRY-RUN: would delete Entra device object $objectId"
        }
        Invoke-GraphRequest -Method DELETE -Path "devices/$objectId" | Out-Null
        Write-AtLog -Message "Deleted Entra device object $objectId." -Properties $LogProperties
        return New-ProviderResult -Status 'Success' -Detail "deleted Entra device object $objectId"
    }
    catch {
        $status = Get-HttpStatus -ErrorRecord $_
        if ($status -eq 404) {
            return New-ProviderResult -Status 'Skipped' -Detail 'not present in Entra ID'
        }
        $transient = ($status -eq 429 -or $status -ge 500)
        return New-ProviderResult -Status 'Failed' -Detail $_.Exception.Message -Transient:$transient
    }
}

function Get-EntraDeviceStatus {
    <#
        .SYNOPSIS
            Re-checks live status for the polling engine: Success when the object is gone,
            transient Failure while it still exists. Parity with EntraIdDeleteProvider.GetStatusAsync.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Context)
    try {
        $objectId = Resolve-EntraDeviceObjectId -Context $Context
        if (-not $objectId -or -not (Test-EntraDeviceExists -ObjectId $objectId)) {
            return New-ProviderResult -Status 'Success' -Detail 'not present in Entra ID'
        }
        return New-ProviderResult -Status 'Failed' -Detail "Entra device object still present: $objectId" -Transient
    }
    catch {
        $status = Get-HttpStatus -ErrorRecord $_
        if ($status -eq 404) {
            return New-ProviderResult -Status 'Success' -Detail 'not present in Entra ID'
        }
        $transient = ($status -eq 429 -or $status -ge 500)
        return New-ProviderResult -Status 'Failed' -Detail $_.Exception.Message -Transient:$transient
    }
}

Export-ModuleMember -Function Resolve-EntraDeviceObjectId, Test-EntraDeviceExists, Remove-EntraDevice, Get-EntraDeviceStatus
