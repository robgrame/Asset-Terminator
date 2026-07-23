@{
    RootModule        = 'AT.Contracts.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c4e2a1b0-8d5f-4b2c-a03e-2b3c4d5e6f70'
    Author            = 'Asset-Terminator'
    Description       = 'Request/response contracts and enum value sets (parity with AssetTerminator.Contracts).'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Get-DecommissionTargets', 'Get-DispositionTypes', 'Get-DeviceTypes', 'Get-AssetCategories',
        'New-DecommissionRequest', 'New-AcceptedResponse'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
