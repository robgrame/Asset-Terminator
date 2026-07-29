# Service Bus publishing over the REST API with a managed-identity token.
#
# The REST API is used instead of an output binding because the pipeline needs
# per-message brokered properties that the PowerShell output binding does not
# expose: MessageId (duplicate detection), SessionId (per-device ordering) and
# custom application properties (the SQL filters of the topic subscriptions).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/AT.Common.psm1"

function Send-ServiceBusMessage {
    param(
        [Parameter(Mandatory)] [string] $Entity,
        [Parameter(Mandatory)] $Body,
        [Parameter(Mandatory)] [string] $MessageId,
        [string] $SessionId,
        [string] $CorrelationId,
        [hashtable] $ApplicationProperties
    )

    $namespace = Get-AppSetting -Name 'SERVICEBUS_FQDN' -Required
    $uri = "https://$namespace/$Entity/messages"

    $token = Get-ManagedIdentityToken -Resource 'https://servicebus.azure.net/'

    $brokerProperties = @{ MessageId = $MessageId }
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) { $brokerProperties['SessionId'] = $SessionId }
    if (-not [string]::IsNullOrWhiteSpace($CorrelationId)) { $brokerProperties['CorrelationId'] = $CorrelationId }

    $headers = @{
        'Authorization'    = "Bearer $token"
        'BrokerProperties' = ($brokerProperties | ConvertTo-Json -Compress)
    }

    # Custom application properties travel as HTTP headers; string values must be
    # quoted so Service Bus types them as strings rather than as raw tokens.
    if ($ApplicationProperties) {
        foreach ($key in $ApplicationProperties.Keys) {
            $value = $ApplicationProperties[$key]
            if ($null -eq $value) { continue }
            if ($value -is [bool]) {
                $headers[$key] = $value.ToString().ToLowerInvariant()
            }
            elseif ($value -is [int] -or $value -is [long] -or $value -is [double]) {
                $headers[$key] = "$value"
            }
            else {
                $headers[$key] = '"' + ("$value").Replace('"', '\"') + '"'
            }
        }
    }

    $payload = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 12 }

    Invoke-RestMethod -Uri $uri -Method POST -Headers $headers `
        -ContentType 'application/json;charset=utf-8' -Body $payload | Out-Null

    return $MessageId
}

Export-ModuleMember -Function Send-ServiceBusMessage
