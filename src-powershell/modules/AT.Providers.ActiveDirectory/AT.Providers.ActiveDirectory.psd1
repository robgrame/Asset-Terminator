@{
    RootModule        = 'AT.Providers.ActiveDirectory.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c3d4e5f6-3344-4c7d-ae8f-90a1b2c3d4e5'
    Author            = 'Asset-Terminator'
    Description       = 'On-prem Active Directory computer cleanup via ADSI/LDAP: find/delete/status (parity with AssetTerminator.Providers.ActiveDirectory).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('AT.Common', 'AT.Core')
    FunctionsToExport = @(
        'Find-AdComputerDistinguishedName', 'Remove-AdComputerByDistinguishedName',
        'Remove-AdComputer', 'Get-AdComputerStatus'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
