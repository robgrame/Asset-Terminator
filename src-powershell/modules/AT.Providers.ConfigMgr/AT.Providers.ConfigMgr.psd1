@{
    RootModule        = 'AT.Providers.ConfigMgr.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'd4e5f6a7-4455-4d8e-bf90-a1b2c3d4e5f6'
    Author            = 'Asset-Terminator'
    Description       = 'On-prem ConfigMgr (SCCM) cleanup via AdminService OData REST: find/delete/status (parity with AssetTerminator.Providers.ConfigMgr).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('AT.Common', 'AT.Core')
    FunctionsToExport = @(
        'ConvertTo-SccmDeviceName', 'Invoke-SccmRequest', 'Test-SccmTransientStatus',
        'Get-SccmResourceIdFromResponse', 'Find-SccmDeviceResourceId', 'Remove-SccmDeviceResource',
        'Remove-SccmDevice', 'Get-SccmDeviceStatus'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
