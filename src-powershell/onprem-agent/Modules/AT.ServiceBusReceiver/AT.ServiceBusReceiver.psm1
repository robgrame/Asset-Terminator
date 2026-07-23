# AT.ServiceBusReceiver.psm1  (on-prem agent)
# Service Bus queue *receive* over the data-plane REST API (peek-lock), the counterpart of
# AT.Infrastructure\Messaging.psm1 (which only sends). Used by the on-prem agent to pull
# ActionDispatch messages. Auth via Entra token (Managed Identity / Azure Arc / az CLI)
# or a pre-acquired SAS token.

Set-StrictMode -Version Latest

$script:SbResource = 'https://servicebus.azure.net'

function Get-SbAuthHeader {
    <# Returns the Authorization header value: SAS if provided, else a bearer token. #>
    [CmdletBinding()]
    param([string] $SasToken)
    if (-not [string]::IsNullOrWhiteSpace($SasToken)) { return $SasToken }
    $token = Get-IdentityToken -Resource $script:SbResource
    return "Bearer $token"
}

function ConvertFrom-BrokerProperties {
    <# Extracts SequenceNumber + LockToken from the BrokerProperties response header JSON. #>
    [CmdletBinding()]
    param([string] $Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try { $bp = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    [pscustomobject]@{
        SequenceNumber = [string](Get-OptionalProp $bp 'SequenceNumber')
        LockToken      = [string](Get-OptionalProp $bp 'LockToken')
        MessageId      = [string](Get-OptionalProp $bp 'MessageId')
    }
}

function Receive-ServiceBusMessage {
    <#
        .SYNOPSIS
            Peek-lock receive of a single message. Returns @{ Body; SequenceNumber; LockToken;
            MessageId; LockLocation } or $null when the queue is empty (HTTP 204).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Namespace,
        [Parameter(Mandatory)][string] $Queue,
        [int] $TimeoutSeconds = 60,
        [string] $SasToken
    )
    $uri = "https://$Namespace/$Queue/messages/head?timeout=$TimeoutSeconds"
    $headers = @{ Authorization = (Get-SbAuthHeader -SasToken $SasToken) }
    try {
        $resp = Invoke-WebRequest -Method Post -Uri $uri -Headers $headers -ErrorAction Stop
    }
    catch {
        if ((Get-HttpStatus -ErrorRecord $_) -eq 204) { return $null }
        throw
    }
    if ($resp.StatusCode -eq 204) { return $null }
    $bp = ConvertFrom-BrokerProperties -Json ([string]($resp.Headers['BrokerProperties']))
    $location = [string]($resp.Headers['Location'])
    [pscustomobject]@{
        Body           = [string]$resp.Content
        SequenceNumber = ($bp ? $bp.SequenceNumber : $null)
        LockToken      = ($bp ? $bp.LockToken : $null)
        MessageId      = ($bp ? $bp.MessageId : $null)
        LockLocation   = $location
    }
}

function Resolve-LockUri {
    <# Prefers the server-provided Location; falls back to /messages/{seq}/{lockToken}. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Message, [Parameter(Mandatory)][string] $Namespace, [Parameter(Mandatory)][string] $Queue)
    $loc = Get-OptionalProp $Message 'LockLocation'
    if (-not [string]::IsNullOrWhiteSpace([string]$loc)) { return [string]$loc }
    $seq = [string](Get-OptionalProp $Message 'SequenceNumber')
    $lock = [string](Get-OptionalProp $Message 'LockToken')
    if ([string]::IsNullOrWhiteSpace($seq) -or [string]::IsNullOrWhiteSpace($lock)) {
        throw 'Cannot resolve lock URI: message has no LockLocation and no SequenceNumber/LockToken.'
    }
    return "https://$Namespace/$Queue/messages/$seq/$lock"
}

function Complete-ServiceBusMessage {
    <# Completes (deletes) a peek-locked message. Parity with ServiceBusReceiver.CompleteMessageAsync. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Message, [Parameter(Mandatory)][string] $Namespace, [Parameter(Mandatory)][string] $Queue, [string] $SasToken)
    $uri = Resolve-LockUri -Message $Message -Namespace $Namespace -Queue $Queue
    $headers = @{ Authorization = (Get-SbAuthHeader -SasToken $SasToken) }
    Invoke-RestMethod -Method Delete -Uri $uri -Headers $headers -ErrorAction Stop | Out-Null
}

function Suspend-ServiceBusMessage {
    <# Abandons (unlocks) a peek-locked message so it is redelivered. Parity with AbandonMessageAsync. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Message, [Parameter(Mandatory)][string] $Namespace, [Parameter(Mandatory)][string] $Queue, [string] $SasToken)
    $uri = Resolve-LockUri -Message $Message -Namespace $Namespace -Queue $Queue
    $headers = @{ Authorization = (Get-SbAuthHeader -SasToken $SasToken) }
    Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ErrorAction Stop | Out-Null
}

Export-ModuleMember -Function Get-SbAuthHeader, ConvertFrom-BrokerProperties, Receive-ServiceBusMessage, `
    Resolve-LockUri, Complete-ServiceBusMessage, Suspend-ServiceBusMessage
