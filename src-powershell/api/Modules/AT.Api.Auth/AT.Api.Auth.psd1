@{
    RootModule        = 'AT.Api.Auth.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c3d4e5f6-3344-4c7d-ae8f-90a1b2c3d4e5'
    Author            = 'Asset-Terminator'
    Description       = 'API HTTP auth: API-key + IP allowlist gate and caller RBAC (parity with AssetTerminator.Api.Auth).'
    PowerShellVersion = '7.4'
    RequiredModules   = @('AT.Core')
    FunctionsToExport = @(
        'Get-AppRoles', 'Get-HeaderValue', 'Test-FixedTimeEqual', 'Test-CidrMatch',
        'Test-IpAllowed', 'Get-RemoteIp', 'Test-HttpAuthGate', 'Get-CallerPrincipal',
        'Get-CallerUpn', 'Get-CallerRoles', 'Test-CallerInRole'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
