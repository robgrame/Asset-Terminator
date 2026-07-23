@{
    RootModule        = 'AT.Guardrails.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'f7b5d4e3-b082-4e5f-d361-5e6f708192a3'
    Author            = 'Asset-Terminator'
    Description       = 'Config-driven guardrail engine with override hook (parity with AssetTerminator.Guardrails / IWipeGuardrail).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('AT.Common')
    FunctionsToExport = @(
        'New-GuardrailResult', 'Register-Guardrail', 'Invoke-Guardrails',
        'Test-EncryptionGuardrail', 'Test-InactivityGuardrail', 'Test-CriticalGroupGuardrail'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
