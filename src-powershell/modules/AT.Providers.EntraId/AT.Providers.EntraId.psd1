@{
    RootModule        = 'AT.Providers.EntraId.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b2c3d4e5-2233-4b6c-9d7e-8f90a1b2c3d4'
    Author            = 'Asset-Terminator'
    Description       = 'Entra ID directory device provider: lookup + delete + status (parity with AssetTerminator.Providers.EntraId).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('AT.Common', 'AT.Core')
    FunctionsToExport = @(
        'Resolve-EntraDeviceObjectId', 'Test-EntraDeviceExists', 'Remove-EntraDevice', 'Get-EntraDeviceStatus'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
