@{
    RootModule        = 'AT.Infrastructure.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'e6a4c3d2-af71-4d4e-c250-4d5e6f708192'
    Author            = 'Asset-Terminator'
    Description       = 'Infrastructure adapters: SLA, WORM audit, SQL state store, Service Bus, callbacks, secrets, observability. Parity with AssetTerminator.Infrastructure.'
    PowerShellVersion = '7.4'
    RequiredModules   = @('AT.Common')
    NestedModules     = @('Sla.psm1', 'Audit.psm1', 'SqlStateStore.psm1', 'Messaging.psm1', 'Callbacks.psm1', 'Secrets.psm1', 'Observability.psm1')
    FunctionsToExport = @(
        'Get-DefaultSlaConfig', 'Get-SlaDueAt', 'Get-SlaState',
        'New-AuditRecord', 'Get-AuditHash', 'ConvertTo-BlobPrefix', 'Test-AuditChain',
        'Get-AuditConfig', 'Get-AuditBlobNames', 'Get-AuditBlob', 'Add-AuditRecord', 'Get-AuditTimeline',
        'Test-IsTerminalState', 'New-SqlConnection', 'Invoke-SqlNonQuery', 'Invoke-SqlQuery',
        'Get-DecommissionRequest', 'New-DecommissionRequestRow', 'Set-RequestState', 'Set-ActionStatus',
        'Get-ActiveRequests', 'Add-GuardrailOverride', 'Get-GuardrailOverride', 'Set-DeviceContextJson', 'Set-ActionNextPoll',
        'Test-IsOnPremTarget', 'Get-MessagingConfig', 'Send-ServiceBusMessage', 'Start-DecommissionWorkflow', 'Send-ActionDispatch',
        'New-ServiceNowCallback', 'Get-BackoffDelay', 'Get-CallbackAuthHeader', 'Send-ServiceNowCallback', 'Send-CallbackToDeadLetter',
        'Resolve-Secret',
        'Send-Telemetry', 'Send-RequestSnapshot'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
