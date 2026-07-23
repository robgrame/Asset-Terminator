@{
    RootModule        = 'AT.Core.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'd5f3b2c1-9e60-4c3d-b14f-3c4d5e6f7081'
    Author            = 'Asset-Terminator'
    Description       = 'Domain core: state model, request validation and target resolution (parity with AssetTerminator.Core + IntakeService).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('AT.Contracts')
    FunctionsToExport = @(
        'Get-RequestStates', 'Get-ActionStatuses', 'Get-SlaStates', 'Get-GuardrailSeverities',
        'Test-DecommissionRequest', 'Resolve-DecommissionTarget', 'Get-ActionLabel', 'New-DecommissionRecord',
        'New-ProviderResult', 'New-DeviceContext', 'Get-OptionalProp'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
