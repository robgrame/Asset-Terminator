# Messaging.psm1  (nested in AT.Infrastructure)
# Service Bus dispatch over the data-plane REST API with a Managed Identity token
# (passwordless). Parity with AssetTerminator.Infrastructure.Messaging
# (ServiceBusActionDispatcher + ServiceBusWorkflowStarter).
#
# Configuration (app settings):
#   SB_NAMESPACE          : fully-qualified namespace (ns.servicebus.windows.net)
#   SB_ORCHESTRATION_QUEUE: default 'decommission-orchestration'
#   SB_CLOUD_QUEUE        : default 'decommission-cloud'
#   SB_ONPREM_QUEUE       : default 'decommission-onprem'

Set-StrictMode -Version Latest

$script:SbResource   = 'https://servicebus.azure.net'
$script:OnPremTargets = @('ActiveDirectory', 'ConfigMgr', 'LicenseRemoval', 'BiosPasswordRemoval')

function Test-IsOnPremTarget {
    <#
        .SYNOPSIS
            True when a target must run on the on-prem agent. Parity with IsOnPrem.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Target)
    return $Target -in $script:OnPremTargets
}

function Get-MessagingConfig {
    [CmdletBinding()] param()
    $ns = $env:SB_NAMESPACE
    if (-not $ns) { throw 'SB_NAMESPACE app setting is not configured.' }
    [pscustomobject]@{
        Namespace          = $ns
        OrchestrationQueue = ($env:SB_ORCHESTRATION_QUEUE ? $env:SB_ORCHESTRATION_QUEUE : 'decommission-orchestration')
        CloudQueue         = ($env:SB_CLOUD_QUEUE ? $env:SB_CLOUD_QUEUE : 'decommission-cloud')
        OnPremQueue        = ($env:SB_ONPREM_QUEUE ? $env:SB_ONPREM_QUEUE : 'decommission-onprem')
    }
}

function Send-ServiceBusMessage {
    <#
        .SYNOPSIS
            Sends a JSON message to a Service Bus queue via REST + MI token.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Queue,
        [Parameter(Mandatory)] $Body,
        [string] $MessageId,
        [string] $Subject
    )
    $cfg = Get-MessagingConfig
    $uri = "https://$($cfg.Namespace)/$Queue/messages"
    $props = @{}
    if ($MessageId) { $props['MessageId'] = $MessageId }
    if ($Subject)   { $props['Label'] = $Subject }
    $brokerProps = ($props.Count -gt 0) ? ($props | ConvertTo-Json -Compress) : $null

    Invoke-AtRetry -ScriptBlock {
        $token = Get-IdentityToken -Resource $script:SbResource
        $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
        if ($brokerProps) { $headers['BrokerProperties'] = $brokerProps }
        $json = ($Body -is [string]) ? $Body : ($Body | ConvertTo-Json -Depth 8 -Compress)
        Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $json -ErrorAction Stop
    } | Out-Null
    Write-AtLog -Message "Enqueued message to $Queue" -Properties @{ messageId = $MessageId; subject = $Subject }
}

function Start-DecommissionWorkflow {
    <#
        .SYNOPSIS
            Enqueues the orchestration-start message. Parity with ServiceBusWorkflowStarter.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RequestId,
        [Parameter(Mandatory)][string] $CorrelationId
    )
    $cfg = Get-MessagingConfig
    Send-ServiceBusMessage -Queue $cfg.OrchestrationQueue `
        -Body @{ requestId = $RequestId; correlationId = $CorrelationId; enqueuedAtUtc = ([datetime]::UtcNow).ToString('o') } `
        -MessageId $RequestId -Subject 'WorkflowStart'
}

function Send-ActionDispatch {
    <#
        .SYNOPSIS
            Routes a sub-action to the cloud or on-prem queue. Parity with
            ServiceBusActionDispatcher.DispatchAsync.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RequestId,
        [Parameter(Mandatory)][string] $Target
    )
    $cfg = Get-MessagingConfig
    $queue = (Test-IsOnPremTarget $Target) ? $cfg.OnPremQueue : $cfg.CloudQueue
    Send-ServiceBusMessage -Queue $queue `
        -Body @{ requestId = $RequestId; target = $Target; enqueuedAtUtc = ([datetime]::UtcNow).ToString('o') } `
        -MessageId "$RequestId`:$Target" -Subject $Target
}

Export-ModuleMember -Function Test-IsOnPremTarget, Get-MessagingConfig, Send-ServiceBusMessage, `
    Start-DecommissionWorkflow, Send-ActionDispatch
