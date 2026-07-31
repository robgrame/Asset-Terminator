Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/AT.Common.psm1"
Import-Module "$PSScriptRoot/AT.State.psm1"

function Get-CallbackEntityProperty {
    param($Entity, [string] $Name, $Default = $null)

    if ($Entity.PSObject.Properties.Name -contains $Name -and $null -ne $Entity.$Name) {
        return $Entity.$Name
    }
    return $Default
}

function Merge-CallbackLogProperties {
    param([hashtable] $Properties, [hashtable] $AdditionalProperties)

    $merged = @{} + $Properties
    foreach ($key in $AdditionalProperties.Keys) {
        $merged[$key] = $AdditionalProperties[$key]
    }
    return $merged
}

function Send-ServiceNowCallback {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] $Payload,
        [int] $MaxAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Invoke-RestMethod -Uri $Url -Method POST -ContentType 'application/json' `
                -Body ($Payload | ConvertTo-Json -Depth 12) -TimeoutSec 30 | Out-Null
            return
        }
        catch {
            if ($attempt -eq $MaxAttempts) { throw }
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
        }
    }
}

function Send-RequestCallback {
    param(
        [Parameter(Mandatory)] $Request,
        [Parameter(Mandatory)] [string] $Status,
        [Parameter(Mandatory)] [datetime] $CompletedAt,
        [string] $ErrorMessage = '',
        $Result,
        [Parameter(Mandatory)] [hashtable] $LogProperties
    )

    $callbackUrl = [string](Get-CallbackEntityProperty -Entity $Request -Name 'callbackUrl' -Default '')
    if ([string]::IsNullOrWhiteSpace($callbackUrl)) { return }

    $callback = [ordered]@{
        requestId         = $Request.RowKey
        correlationId     = $Request.correlationId
        platform          = $Request.PartitionKey
        scenario          = $Request.scenario
        status            = $Status
        device            = [ordered]@{
            serialNumber    = $Request.serialNumber
            imei            = $Request.imei
            deviceName      = $Request.deviceName
            managedDeviceId = $Request.managedDeviceId
        }
        automationJobName = Get-CallbackEntityProperty -Entity $Request -Name 'automationJobName'
        automationJobId   = Get-CallbackEntityProperty -Entity $Request -Name 'automationJobId'
        dispatchedAt      = Get-CallbackEntityProperty -Entity $Request -Name 'dispatchedAt'
        completedAt       = $CompletedAt.ToUniversalTime().ToString('o')
        errorMessage      = $ErrorMessage
        result            = $Result
    }

    try {
        Send-ServiceNowCallback -Url $callbackUrl -Payload $callback
        Update-WipeRequestState -Platform $Request.PartitionKey -RequestId $Request.RowKey -Properties @{ callbackStatus = 'Sent' }
        Write-AtAudit -Action 'WipeCallbackSent' -Properties (Merge-CallbackLogProperties -Properties $LogProperties -AdditionalProperties @{ status = $Status })
    }
    catch {
        Write-AtLog -Level 'Error' -Message "Callback failed: $($_.Exception.Message)" -Properties $LogProperties
        Write-AtAudit -Action 'WipeCallbackFailed' -Level 'Error' -Properties (Merge-CallbackLogProperties -Properties $LogProperties -AdditionalProperties @{
            status = $Status
            error = $_.Exception.Message
        })
        Update-WipeRequestState -Platform $Request.PartitionKey -RequestId $Request.RowKey -Properties @{
            callbackStatus = 'Failed'
            callbackError = $_.Exception.Message
        }
    }
}

Export-ModuleMember -Function Send-RequestCallback
