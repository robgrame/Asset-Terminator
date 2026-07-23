@{
    RootModule        = 'AT.Providers.Intune.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a1b2c3d4-1122-4a5b-8c6d-7e8f90a1b2c3'
    Author            = 'Asset-Terminator'
    Description       = 'Intune/Graph device provider: wipe, retire, delete, Autopilot delete (parity with AssetTerminator.Providers.Intune).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('AT.Common')
    FunctionsToExport = @(
        'Select-FreshestManagedDevice', 'Get-IntuneManagedDevice', 'Invoke-IntuneWipe',
        'Invoke-IntuneRetire', 'Remove-IntuneManagedDevice', 'Remove-AutopilotDevice',
        'Resolve-IntuneDeviceFromContext', 'Get-IntuneWipeStatus', 'Get-IntuneRetireStatus', 'Get-IntuneDeleteStatus'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
