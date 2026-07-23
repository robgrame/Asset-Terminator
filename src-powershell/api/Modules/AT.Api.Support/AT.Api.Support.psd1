@{
    RootModule        = 'AT.Api.Support.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'd4e5f6a7-4455-4d8e-bf90-a1b2c3d4e5f6'
    Author            = 'Asset-Terminator'
    Description       = 'API config binding + HTTP helpers (parity with .NET Options binding).'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Get-ConfigValue', 'Get-ConfigBool', 'Get-ConfigList', 'Get-IngestionOptions',
        'Get-PreWipeOptions', 'Get-OverrideRequiredFor', 'Write-HttpJson', 'ConvertTo-RequestObject',
        'ConvertTo-StatusResponse', 'ConvertTo-HistoryEvent'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
