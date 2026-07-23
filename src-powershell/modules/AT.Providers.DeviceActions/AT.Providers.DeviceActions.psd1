@{
    RootModule        = 'AT.Providers.DeviceActions.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e5f6a7b8-5566-4e9f-c0a1-b2c3d4e5f6a7'
    Author            = 'Asset-Terminator'
    Description       = 'On-device pre-wipe actions: Enterprise license removal + BIOS password removal via OEM tools (parity with AssetTerminator.Providers.DeviceActions).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('AT.Common', 'AT.Core')
    FunctionsToExport = @(
        'Expand-CommandTemplate', 'Test-CommandSpecConfigured', 'Invoke-LocalCommand',
        'Resolve-DeviceManufacturer', 'ConvertTo-DeviceActionResult', 'Get-DeviceActionTimeoutSeconds',
        'Invoke-LicenseRemoval', 'Invoke-BiosPasswordRemoval', 'Get-DeviceActionPendingStatus'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
