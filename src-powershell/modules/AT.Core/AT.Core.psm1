# AT.Core.psm1
# Domain core for the parallel PowerShell implementation. Parity with
# AssetTerminator.Core + the request validation / target-resolution logic that
# lives in AssetTerminator.Api.Services.IntakeService.
#
#   * lifecycle/state enum value sets (RequestState, ActionStatus, SlaState,
#     GuardrailSeverity)
#   * Test-DecommissionRequest  -> validation (returns $null when valid, else error)
#   * Resolve-DecommissionTarget -> effective sub-action set, applying disposition
#     rules + pre-wipe auto-injection
#   * Get-ActionLabel, New-DecommissionRecord

Set-StrictMode -Version Latest

$script:RequestStates      = @('Requested', 'Validated', 'GuardrailsFailed', 'InProgress', 'PartiallyCompleted', 'Completed', 'Failed', 'TimedOut')
$script:ActionStatuses     = @('Pending', 'InProgress', 'Success', 'Skipped', 'Failed', 'Blocked', 'TimedOut')
$script:SlaStates          = @('WithinSla', 'AtRisk', 'Breached')
$script:GuardrailSeverities = @('Info', 'Warning', 'Blocking')

# Targets that are only valid for a Terminate disposition.
$script:TerminateOnlyTargets = @('Wipe', 'Autopilot', 'LicenseRemoval', 'BiosPasswordRemoval')

function Get-RequestStates       { [CmdletBinding()] param() ,$script:RequestStates }
function Get-ActionStatuses      { [CmdletBinding()] param() ,$script:ActionStatuses }
function Get-SlaStates           { [CmdletBinding()] param() ,$script:SlaStates }
function Get-GuardrailSeverities { [CmdletBinding()] param() ,$script:GuardrailSeverities }

function Test-DecommissionRequest {
    <#
        .SYNOPSIS
            Validates a (normalized) decommission request. Parity with
            IntakeService.Validate.
        .OUTPUTS
            [string] error message, or $null when the request is valid.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Request)

    if ([string]::IsNullOrWhiteSpace($Request.requestId)) { return 'requestId is required.' }
    if ([string]::IsNullOrWhiteSpace($Request.assetId)) { return 'assetId is required.' }
    if (-not $Request.requestedActions -or @($Request.requestedActions).Count -eq 0) {
        return 'requestedActions must contain at least one action.'
    }
    if ([string]::IsNullOrWhiteSpace($Request.deviceName) -and [string]::IsNullOrWhiteSpace($Request.serialNumber)) {
        return 'deviceName or serialNumber is required to locate the device.'
    }
    if ($Request.deviceType -notin (Get-DeviceTypes)) { return 'deviceType is invalid.' }
    if ($Request.dispositionType -notin (Get-DispositionTypes)) { return 'dispositionType is invalid.' }

    $actions = @($Request.requestedActions)
    $invalidTargets = $actions | Where-Object { $_ -notin (Get-DecommissionTargets) }
    if ($invalidTargets) { return "requestedActions contains invalid target(s): $($invalidTargets -join ', ')." }

    if ($Request.dispositionType -eq 'Retire') {
        $forbidden = $actions | Where-Object { $_ -in $script:TerminateOnlyTargets }
        if ($forbidden) { return "dispositionType Retire cannot include $($forbidden -join ', ')." }
    }
    elseif ($actions -contains 'Retire') {
        return 'dispositionType Terminate cannot include the Retire action.'
    }

    if (($actions -contains 'Autopilot') -and [string]::IsNullOrWhiteSpace($Request.serialNumber)) {
        return 'serialNumber is required to remove the device from Autopilot.'
    }

    return $null
}

function Resolve-DecommissionTarget {
    <#
        .SYNOPSIS
            Resolves the effective set of sub-action targets, applying disposition
            rules and pre-wipe auto-injection. Parity with IntakeService.ResolveTargets.
        .PARAMETER PreWipe
            Hashtable with DeleteFromAutopilot / RemoveEnterpriseLicense /
            RemoveBiosPassword booleans (defaults: all enabled).
        .OUTPUTS
            [string[]] the resolved, de-duplicated target set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Request,
        [hashtable] $PreWipe = @{ DeleteFromAutopilot = $true; RemoveEnterpriseLicense = $true; RemoveBiosPassword = $true }
    )

    $targets = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($a in @($Request.requestedActions)) { [void]$targets.Add([string]$a) }

    if ($Request.dispositionType -eq 'Retire') {
        [void]$targets.Add('Retire')
        [void]$targets.Remove('Wipe')
        return @($targets)
    }

    # Terminate: auto-inject pre-wipe preventive actions for a Windows wipe.
    if ($targets.Contains('Wipe') -and $Request.deviceType -eq 'Windows') {
        if (($PreWipe.DeleteFromAutopilot) -and -not [string]::IsNullOrWhiteSpace($Request.serialNumber)) { [void]$targets.Add('Autopilot') }
        if ($PreWipe.RemoveEnterpriseLicense) { [void]$targets.Add('LicenseRemoval') }
        if ($PreWipe.RemoveBiosPassword) { [void]$targets.Add('BiosPasswordRemoval') }
    }

    return @($targets)
}

function Get-ActionLabel {
    <#
        .SYNOPSIS
            Maps a target to its action label. Parity with IntakeService.ActionLabel.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Target)
    switch ($Target) {
        'Wipe'                { 'Wipe' }
        'Retire'              { 'Retire' }
        'Autopilot'           { 'DeleteAutopilot' }
        'LicenseRemoval'      { 'RemoveLicense' }
        'BiosPasswordRemoval' { 'RemoveBiosPassword' }
        default               { 'Delete' }
    }
}

function Get-OptionalProp {
    param($Object, [string] $Name)
    if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

function New-DecommissionRecord {
    <#
        .SYNOPSIS
            Builds the initial DecommissionRecord (current-state) object for a
            validated request. Parity with IntakeService record construction.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Request,
        [Parameter(Mandatory)][string] $CorrelationId,
        [datetime] $NowUtc = ([datetime]::UtcNow),
        [datetime] $DueAtUtc,
        [hashtable] $PreWipe
    )

    $resolveParams = @{ Request = $Request }
    if ($PreWipe) { $resolveParams.PreWipe = $PreWipe }
    $targets = Resolve-DecommissionTarget @resolveParams

    $actions = foreach ($t in $targets) {
        [pscustomobject][ordered]@{
            requestId = $Request.requestId
            target    = $t
            action    = Get-ActionLabel -Target $t
            status    = 'Pending'
        }
    }

    [pscustomobject][ordered]@{
        requestId        = $Request.requestId
        correlationId    = $CorrelationId
        assetId          = $Request.assetId
        deviceName       = Get-OptionalProp $Request 'deviceName'
        serialNumber     = Get-OptionalProp $Request 'serialNumber'
        primaryUserUpn   = Get-OptionalProp $Request 'primaryUserUpn'
        deviceType       = $Request.deviceType
        assetCategory    = $Request.assetCategory
        dispositionType  = $Request.dispositionType
        ticketNumber     = Get-OptionalProp $Request 'ticketNumber'
        requestor        = Get-OptionalProp $Request 'requestor'
        dryRun           = [bool](Get-OptionalProp $Request 'dryRun')
        state            = 'Requested'
        createdAtUtc     = $NowUtc.ToString('o')
        lastUpdatedAtUtc = $NowUtc.ToString('o')
        dueAtUtc         = if ($PSBoundParameters.ContainsKey('DueAtUtc')) { $DueAtUtc.ToString('o') } else { $null }
        actions          = @($actions)
    }
}

function New-ProviderResult {
    <#
        .SYNOPSIS
            Builds a provider result (parity with AssetTerminator.Core.Abstractions.ProviderResult).
            -Status one of Success/Skipped/Failed; -Transient marks retryable failures.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Success', 'Skipped', 'Failed')][string] $Status,
        [string] $Detail,
        [switch] $Transient
    )
    [pscustomobject]@{
        Status    = $Status
        Detail    = $Detail
        Transient = [bool]$Transient
    }
}

function New-DeviceContext {
    <#
        .SYNOPSIS
            Builds the device context passed to cleanup providers (parity with
            AssetTerminator.Core.Domain.DeviceContext).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Record)
    [pscustomobject]@{
        RequestId       = Get-OptionalProp $Record 'requestId'
        AssetId         = Get-OptionalProp $Record 'assetId'
        DeviceName      = Get-OptionalProp $Record 'deviceName'
        SerialNumber    = Get-OptionalProp $Record 'serialNumber'
        PrimaryUserUpn  = Get-OptionalProp $Record 'primaryUserUpn'
        IntuneDeviceId  = Get-OptionalProp $Record 'intuneDeviceId'
        EntraDeviceId   = Get-OptionalProp $Record 'entraDeviceId'
        DeviceType      = Get-OptionalProp $Record 'deviceType'
        DryRun          = [bool](Get-OptionalProp $Record 'dryRun')
    }
}

Export-ModuleMember -Function Get-RequestStates, Get-ActionStatuses, Get-SlaStates, Get-GuardrailSeverities, `
    Test-DecommissionRequest, Resolve-DecommissionTarget, Get-ActionLabel, New-DecommissionRecord, `
    New-ProviderResult, New-DeviceContext, Get-OptionalProp
