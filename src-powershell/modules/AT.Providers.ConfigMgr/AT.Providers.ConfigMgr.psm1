# AT.Providers.ConfigMgr.psm1
# On-prem ConfigMgr (SCCM) cleanup via the AdminService OData REST API.
# Parity with AssetTerminator.Providers.ConfigMgr (SccmAdminService + ConfigMgrCleanupProvider).
# Uses Windows-integrated auth (-UseDefaultCredentials) or an explicit -Credential.

Set-StrictMode -Version Latest

function ConvertTo-SccmDeviceName {
    <# Normalizes an FQDN/host to the bare NetBIOS name used by SMS_R_System.Name. #>
    [CmdletBinding()]
    param([string] $DeviceName)
    if ([string]::IsNullOrWhiteSpace($DeviceName)) { return $null }
    $n = $DeviceName.Trim().TrimEnd('.')
    $dot = $n.IndexOf('.')
    if ($dot -gt 0) { return $n.Substring(0, $dot) }
    return $n
}

function Invoke-SccmRequest {
    <#
        .SYNOPSIS
            Thin AdminService HTTP wrapper. Returns @{ StatusCode; Content } and never throws
            on HTTP status; transport/timeout errors surface StatusCode 0.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [pscredential] $Credential
    )
    $params = @{ Method = $Method; Uri = $Uri; ErrorAction = 'Stop' }
    if ($Credential) { $params['Credential'] = $Credential } else { $params['UseDefaultCredentials'] = $true }
    try {
        $content = Invoke-RestMethod @params
        return @{ StatusCode = 200; Content = $content }
    }
    catch {
        return @{ StatusCode = (Get-HttpStatus -ErrorRecord $_); Content = $null; Message = $_.Exception.Message }
    }
}

function Test-SccmTransientStatus {
    param([int] $StatusCode)
    return ($StatusCode -eq 0 -or $StatusCode -eq 408 -or $StatusCode -ge 500)
}

function Get-SccmResourceIdFromResponse {
    <# Extracts the first ResourceId from an AdminService OData response payload. #>
    [CmdletBinding()]
    param($Content)
    if ($null -eq $Content) { return $null }
    $items = if ($Content.PSObject.Properties['value']) { @($Content.value) } else { @($Content) }
    foreach ($item in $items) {
        if ($null -ne $item -and $item.PSObject.Properties['ResourceId']) {
            $rid = $item.ResourceId
            $parsed = 0L
            if ([long]::TryParse([string]$rid, [ref]$parsed)) { return $parsed }
        }
    }
    return $null
}

function Find-SccmDeviceResourceId {
    <#
        .SYNOPSIS
            Resolves a device ResourceId by Name (then SerialNumber), or $null.
            Parity with SccmAdminService.FindDeviceResourceIdAsync.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $BaseUrl,
        [string] $DeviceName,
        [string] $SerialNumber,
        [pscredential] $Credential
    )
    $base = $BaseUrl.TrimEnd('/')
    $filters = @()
    $name = ConvertTo-SccmDeviceName -DeviceName $DeviceName
    if (-not [string]::IsNullOrWhiteSpace($name)) { $filters += "Name eq '$($name -replace "'", "''")'" }
    if (-not [string]::IsNullOrWhiteSpace($SerialNumber)) { $filters += "SerialNumber eq '$($SerialNumber.Trim() -replace "'", "''")'" }
    foreach ($filter in $filters) {
        $uri = "$base/wmi/SMS_R_System?`$filter=$([uri]::EscapeDataString($filter))"
        $resp = Invoke-SccmRequest -Method GET -Uri $uri -Credential $Credential
        if ($resp.StatusCode -eq 404) { continue }
        if ($resp.StatusCode -ne 200) {
            throw [System.Exception]::new("ConfigMgr AdminService find failed ($($resp.StatusCode)): $($resp.Message)")
        }
        $rid = Get-SccmResourceIdFromResponse -Content $resp.Content
        if ($null -ne $rid) { return $rid }
    }
    return $null
}

function Remove-SccmDeviceResource {
    <# DELETE wmi/SMS_R_System(<resourceId>). Parity with SccmAdminService.DeleteDeviceAsync. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $BaseUrl, [Parameter(Mandatory)][long] $ResourceId, [pscredential] $Credential)
    $uri = "$($BaseUrl.TrimEnd('/'))/wmi/SMS_R_System($ResourceId)"
    $resp = Invoke-SccmRequest -Method DELETE -Uri $uri -Credential $Credential
    if ($resp.StatusCode -ne 200 -and $resp.StatusCode -ne 204) {
        throw [System.Exception]::new("ConfigMgr AdminService delete failed ($($resp.StatusCode)): $($resp.Message)")
    }
}

function Remove-SccmDevice {
    <#
        .SYNOPSIS
            Deletes a device from ConfigMgr. Parity with ConfigMgrCleanupProvider.DeleteAsync.
        .OUTPUTS
            ProviderResult (Success | Skipped | Failed[/Transient]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][string] $BaseUrl,
        [switch] $DryRun,
        [pscredential] $Credential,
        [hashtable] $LogProperties = @{}
    )
    try {
        $rid = Find-SccmDeviceResourceId -BaseUrl $BaseUrl -DeviceName (Get-OptionalProp $Context 'DeviceName') `
            -SerialNumber (Get-OptionalProp $Context 'SerialNumber') -Credential $Credential
        if ($null -eq $rid) { return New-ProviderResult -Status 'Skipped' -Detail 'device not found in ConfigMgr' }
        if ($DryRun) {
            Write-AtLog -Message "DRY-RUN: would delete ConfigMgr resourceId $rid" -Properties $LogProperties
            return New-ProviderResult -Status 'Success' -Detail "[DRY-RUN] would delete resourceId $rid"
        }
        Remove-SccmDeviceResource -BaseUrl $BaseUrl -ResourceId $rid -Credential $Credential
        Write-AtLog -Message "Deleted ConfigMgr resourceId $rid" -Properties $LogProperties
        return New-ProviderResult -Status 'Success' -Detail "deleted resourceId $rid"
    }
    catch {
        $status = Get-HttpStatus -ErrorRecord $_
        Write-AtLog -Level 'Warning' -Message "ConfigMgr delete failed: $($_.Exception.Message)" -Properties $LogProperties
        return New-ProviderResult -Status 'Failed' -Detail $_.Exception.Message -Transient:(Test-SccmTransientStatus -StatusCode $status)
    }
}

function Get-SccmDeviceStatus {
    <#
        .SYNOPSIS
            Live status for reconciliation. Parity with ConfigMgrCleanupProvider.GetStatusAsync.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][string] $BaseUrl, [pscredential] $Credential)
    try {
        $rid = Find-SccmDeviceResourceId -BaseUrl $BaseUrl -DeviceName (Get-OptionalProp $Context 'DeviceName') `
            -SerialNumber (Get-OptionalProp $Context 'SerialNumber') -Credential $Credential
        if ($null -eq $rid) { return New-ProviderResult -Status 'Success' -Detail 'device not found in ConfigMgr' }
        return New-ProviderResult -Status 'Failed' -Detail "device still exists in ConfigMgr: resourceId $rid" -Transient
    }
    catch {
        $status = Get-HttpStatus -ErrorRecord $_
        return New-ProviderResult -Status 'Failed' -Detail $_.Exception.Message -Transient:(Test-SccmTransientStatus -StatusCode $status)
    }
}

Export-ModuleMember -Function ConvertTo-SccmDeviceName, Invoke-SccmRequest, Test-SccmTransientStatus, `
    Get-SccmResourceIdFromResponse, Find-SccmDeviceResourceId, Remove-SccmDeviceResource, `
    Remove-SccmDevice, Get-SccmDeviceStatus
