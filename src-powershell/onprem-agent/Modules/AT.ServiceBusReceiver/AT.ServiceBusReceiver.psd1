@{
    RootModule        = 'AT.ServiceBusReceiver.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a7b8c9d0-7788-40b1-e2c3-d4e5f6a7b8c9'
    Author            = 'Asset-Terminator'
    Description       = 'Service Bus data-plane receive (peek-lock/complete/abandon) via REST for the on-prem agent.'
    PowerShellVersion = '7.4'
    RequiredModules   = @('AT.Common', 'AT.Core')
    FunctionsToExport = @(
        'Get-SbAuthHeader', 'ConvertFrom-BrokerProperties', 'Receive-ServiceBusMessage',
        'Resolve-LockUri', 'Complete-ServiceBusMessage', 'Suspend-ServiceBusMessage'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
