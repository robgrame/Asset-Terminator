# AT.Contracts.psm1
# Shared request/response contract for the parallel PowerShell implementation.
# Parity with AssetTerminator.Contracts: enum value sets, the inbound
# DecommissionRequest shape and its response envelopes.
#
# PowerShell has no compile-time enums shared across module boundaries, so the
# canonical enum values are exported as read-only string arrays and every value
# is validated at the boundary (New-DecommissionRequest / Test-* in AT.Core).

Set-StrictMode -Version Latest

# --- Enum value sets (parity with Contracts/Enums.cs) ---
$script:DecommissionTargets = @(
    'ActiveDirectory', 'ConfigMgr', 'Intune', 'EntraId', 'Wipe',
    'Autopilot', 'LicenseRemoval', 'BiosPasswordRemoval', 'Retire'
)
$script:DispositionTypes = @('Terminate', 'Retire')
$script:DeviceTypes      = @('Windows', 'MacOS', 'iOS', 'Android')
$script:AssetCategories  = @('Standard', 'Vip', 'Critical')

function Get-DecommissionTargets { [CmdletBinding()] param() ,$script:DecommissionTargets }
function Get-DispositionTypes    { [CmdletBinding()] param() ,$script:DispositionTypes }
function Get-DeviceTypes         { [CmdletBinding()] param() ,$script:DeviceTypes }
function Get-AssetCategories     { [CmdletBinding()] param() ,$script:AssetCategories }

function New-DecommissionRequest {
    <#
        .SYNOPSIS
            Parses/normalizes a raw ServiceNow request (JSON string or object) into
            the canonical request object with defaults applied.
        .DESCRIPTION
            Applies the same defaults as the .NET DTO: AssetCategory=Standard,
            DispositionType=Terminate, DryRun=false when omitted. Does NOT validate;
            call Test-DecommissionRequest (AT.Core) for validation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $InputObject
    )
    process {
        $o = if ($InputObject -is [string]) { $InputObject | ConvertFrom-Json } else { $InputObject }

        $actions = @()
        if ($o.PSObject.Properties['requestedActions'] -and $o.requestedActions) {
            $actions = @($o.requestedActions)
        }

        [pscustomobject][ordered]@{
            requestId        = [string]$o.requestId
            assetId          = if ($o.PSObject.Properties['assetId']) { [string]$o.assetId } else { '' }
            deviceName       = if ($o.PSObject.Properties['deviceName']) { $o.deviceName } else { $null }
            serialNumber     = if ($o.PSObject.Properties['serialNumber']) { $o.serialNumber } else { $null }
            primaryUserUpn   = if ($o.PSObject.Properties['primaryUserUpn']) { $o.primaryUserUpn } else { $null }
            deviceType       = if ($o.PSObject.Properties['deviceType'] -and $o.deviceType) { [string]$o.deviceType } else { 'Windows' }
            assetCategory    = if ($o.PSObject.Properties['assetCategory'] -and $o.assetCategory) { [string]$o.assetCategory } else { 'Standard' }
            dispositionType  = if ($o.PSObject.Properties['dispositionType'] -and $o.dispositionType) { [string]$o.dispositionType } else { 'Terminate' }
            requestedActions = $actions
            requestor        = if ($o.PSObject.Properties['requestor']) { $o.requestor } else { $null }
            ticketNumber     = if ($o.PSObject.Properties['ticketNumber']) { $o.ticketNumber } else { $null }
            timestamp        = if ($o.PSObject.Properties['timestamp']) { $o.timestamp } else { $null }
            dryRun           = if ($o.PSObject.Properties['dryRun']) { [bool]$o.dryRun } else { $false }
        }
    }
}

function New-AcceptedResponse {
    <#
        .SYNOPSIS
            Builds the 202 Accepted / 200 AlreadyAccepted intake response envelope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RequestId,
        [Parameter(Mandatory)][string] $CorrelationId,
        [Parameter(Mandatory)][bool] $Created,
        [string] $DispositionType = 'Terminate',
        [bool] $DryRun = $true,
        [string] $OverallStatus
    )
    $env = [ordered]@{
        status          = if ($Created) { 'Accepted' } else { 'AlreadyAccepted' }
        requestId       = $RequestId
        correlationId   = $CorrelationId
        dispositionType = $DispositionType
        dryRun          = $DryRun
    }
    if ($OverallStatus) { $env['overallStatus'] = $OverallStatus }
    [pscustomobject]$env
}

Export-ModuleMember -Function Get-DecommissionTargets, Get-DispositionTypes, Get-DeviceTypes, `
    Get-AssetCategories, New-DecommissionRequest, New-AcceptedResponse
