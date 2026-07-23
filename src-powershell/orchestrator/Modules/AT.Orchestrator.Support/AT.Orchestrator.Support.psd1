@{
    RootModule        = 'AT.Orchestrator.Support.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e5f6a7b8-5566-4e9f-c0a1-b2c3d4e5f6a7'
    Author            = 'Asset-Terminator'
    Description       = 'Durable orchestration glue + pure decision logic (parity with AssetTerminator.Orchestrator).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('AT.Common', 'AT.Core', 'AT.Infrastructure', 'AT.Guardrails', 'AT.Providers.Intune', 'AT.Providers.EntraId')
    FunctionsToExport = @(
        'Test-IsObjectDeleteTarget', 'Test-IsObjectDeleteOrAutopilotTarget', 'Test-IsPreWipeGatingTarget',
        'Test-IsOnPremDeleteTarget', 'Test-IsTerminalActionStatus', 'Get-OverallState',
        'Get-ActionUpdateFromResult', 'Get-PreWipeStatus', 'Get-OrchestrationOptions',
        'Get-DefaultGuardrailConfig', 'Get-GuardrailConfig', 'Get-EnrichedDeviceContext', 'Publish-Callback',
        'Get-StoredDeviceContext', 'Invoke-CloudDelete', 'Add-RequestAudit',
        'Get-ReconcileBackoffSeconds', 'Get-ReconcileActionDecision', 'Invoke-ProviderStatus',
        'Invoke-RequestReconcile', 'Invoke-ReconcileAll'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
