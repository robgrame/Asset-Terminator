@{
    RootModule        = 'AT.Agent.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'f6a7b8c9-6677-4fa0-d1b2-c3d4e5f6a7b8'
    Author            = 'Asset-Terminator'
    Description       = 'On-prem agent core: dispatch on-prem actions (AD/ConfigMgr/DeviceActions), persist status + WORM audit (parity with AssetTerminator.OnPremAgent.Worker).'
    PowerShellVersion = '7.4'
    RequiredModules   = @(
        'AT.Common', 'AT.Core', 'AT.Infrastructure',
        'AT.Providers.ActiveDirectory', 'AT.Providers.ConfigMgr', 'AT.Providers.DeviceActions'
    )
    FunctionsToExport = @(
        'ConvertFrom-ActionDispatchMessage', 'Get-AgentDeviceContext', 'Get-AgentActionUpdate',
        'Invoke-AgentProvider', 'Invoke-OnPremAction', 'Add-AgentAudit'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
