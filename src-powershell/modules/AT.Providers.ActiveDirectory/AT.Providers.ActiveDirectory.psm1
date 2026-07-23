# AT.Providers.ActiveDirectory.psm1
# On-prem Active Directory computer-object cleanup via ADSI/LDAP (no RSAT dependency).
# Parity with AssetTerminator.Providers.ActiveDirectory (LdapComputerDirectory +
# ActiveDirectoryCleanupProvider). Destructive calls honour -DryRun.

Set-StrictMode -Version Latest

function Find-AdComputerDistinguishedName {
    <#
        .SYNOPSIS
            Resolves the distinguishedName of a computer object by name, or $null.
            Uses ADSI DirectorySearcher (sAMAccountName '<name>$'). Parity with
            LdapComputerDirectory.FindComputerDnAsync.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $DeviceName, [string] $SearchRoot)
    if ([string]::IsNullOrWhiteSpace($DeviceName)) { return $null }
    $sam = ($DeviceName.TrimEnd('$')) + '$'
    $searcher = if ($SearchRoot) { [adsisearcher]::new([adsi]"LDAP://$SearchRoot") } else { [adsisearcher]::new() }
    try {
        $searcher.Filter = "(&(objectCategory=computer)(sAMAccountName=$($sam -replace '([\\\(\)\*\0])', '\$1')))"
        [void]$searcher.PropertiesToLoad.Add('distinguishedName')
        $result = $searcher.FindOne()
        if (-not $result) { return $null }
        return [string]$result.Properties['distinguishedName'][0]
    }
    finally { $searcher.Dispose() }
}

function Remove-AdComputerByDistinguishedName {
    <# Deletes a computer object (and any leaf children) by DN via ADSI. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $DistinguishedName)
    $entry = [adsi]"LDAP://$DistinguishedName"
    try { $entry.DeleteTree() }
    finally { $entry.Dispose() }
}

function Remove-AdComputer {
    <#
        .SYNOPSIS
            Deletes the AD computer object for a device context. Parity with
            ActiveDirectoryCleanupProvider.DeleteAsync.
        .OUTPUTS
            ProviderResult (Success | Skipped | Failed[/Transient]).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [switch] $DryRun, [string] $SearchRoot, [hashtable] $LogProperties = @{})
    $deviceName = Get-OptionalProp $Context 'DeviceName'
    try {
        $dn = Find-AdComputerDistinguishedName -DeviceName $deviceName -SearchRoot $SearchRoot
        if (-not $dn) { return New-ProviderResult -Status 'Skipped' -Detail 'computer not found in AD' }
        if ($DryRun) {
            Write-AtLog -Message "DRY-RUN: would delete AD computer $dn" -Properties $LogProperties
            return New-ProviderResult -Status 'Success' -Detail "[DRY-RUN] would delete $dn"
        }
        Remove-AdComputerByDistinguishedName -DistinguishedName $dn
        Write-AtLog -Message "Deleted AD computer $dn" -Properties $LogProperties
        return New-ProviderResult -Status 'Success' -Detail "deleted $dn"
    }
    catch {
        Write-AtLog -Level 'Warning' -Message "AD delete failed: $($_.Exception.Message)" -Properties $LogProperties
        return New-ProviderResult -Status 'Failed' -Detail $_.Exception.Message -Transient
    }
}

function Get-AdComputerStatus {
    <#
        .SYNOPSIS
            Live status for reconciliation: Success once the computer is gone, transient
            Failure while it still exists. Parity with ActiveDirectoryCleanupProvider.GetStatusAsync.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [string] $SearchRoot)
    try {
        $dn = Find-AdComputerDistinguishedName -DeviceName (Get-OptionalProp $Context 'DeviceName') -SearchRoot $SearchRoot
        if (-not $dn) { return New-ProviderResult -Status 'Success' -Detail 'computer not found in AD' }
        return New-ProviderResult -Status 'Failed' -Detail "computer still exists in AD: $dn" -Transient
    }
    catch {
        return New-ProviderResult -Status 'Failed' -Detail $_.Exception.Message -Transient
    }
}

Export-ModuleMember -Function Find-AdComputerDistinguishedName, Remove-AdComputerByDistinguishedName, `
    Remove-AdComputer, Get-AdComputerStatus
