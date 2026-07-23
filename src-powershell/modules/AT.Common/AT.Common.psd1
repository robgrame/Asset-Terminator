@{
    RootModule        = 'AT.Common.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b3d1f2a0-7c4e-4a1b-9f2d-1a2b3c4d5e6f'
    Author            = 'Asset-Terminator'
    Description       = 'Foundation primitives (logging, tokens, resilient Graph REST) for the PowerShell parity implementation.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Write-AtLog', 'New-CorrelationId', 'Invoke-AtRetry', 'Get-HttpStatus',
        'Get-IdentityToken', 'Get-GraphToken', 'Invoke-GraphRequest'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
