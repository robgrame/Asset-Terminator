# AT.Agent.psm1
# On-prem agent core: consumes ActionDispatch messages from the on-prem Service Bus queue,
# executes AD / ConfigMgr / DeviceActions against the customer network, writes the outcome
# back to the shared SQL state store and the immutable WORM audit.
# Parity with AssetTerminator.OnPremAgent.Worker (ProcessAsync/BuildContext/ApplyResult) and
# the on-prem IDeviceCleanupProvider implementations.

Set-StrictMode -Version Latest

$script:OnPremTargets = @('ActiveDirectory', 'ConfigMgr', 'LicenseRemoval', 'BiosPasswordRemoval')

function ConvertFrom-ActionDispatchMessage {
    <#
        .SYNOPSIS
            Parses and validates an ActionDispatch message body. Parity with the
            JsonSerializer.Deserialize<ActionDispatchMessage> + empty-message guard in Worker.
        .OUTPUTS
            [pscustomobject]@{ RequestId; Target } — throws on malformed/empty payloads.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { throw 'EmptyMessage: empty body' }
    try { $obj = $Json | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "MalformedJson: $($_.Exception.Message)" }
    $requestId = Get-OptionalProp $obj 'requestId'
    if ([string]::IsNullOrWhiteSpace([string]$requestId)) { throw 'EmptyMessage: missing requestId' }
    [pscustomobject]@{
        RequestId = [string]$requestId
        Target    = [string](Get-OptionalProp $obj 'target')
    }
}

function Get-AgentDeviceContext {
    <# Builds the device context from the stored JSON or the record fields. Parity with Worker.BuildContext. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Record)
    $json = Get-OptionalProp $Record 'DeviceContextJson'
    if (-not $json) { $json = Get-OptionalProp $Record 'deviceContextJson' }
    if (-not [string]::IsNullOrWhiteSpace([string]$json)) {
        try { $ctx = $json | ConvertFrom-Json -ErrorAction Stop; if ($null -ne $ctx) { return $ctx } } catch { }
    }
    return New-DeviceContext -Record $Record
}

function Get-AgentActionUpdate {
    <#
        .SYNOPSIS
            Maps a ProviderResult to the persisted action status/outcome. Parity with
            Worker.ApplyResult: Success/Skipped are final; transient failures revert to
            InProgress (SB redelivery / poller retries); hard failures are final Failed.
        .OUTPUTS
            @{ Status; FinalOutcome }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result)
    $status = [string](Get-OptionalProp $Result 'Status')
    $transient = [bool](Get-OptionalProp $Result 'Transient')
    switch ($status) {
        'Success' { return @{ Status = 'Success'; FinalOutcome = 'Success' } }
        'Skipped' { return @{ Status = 'Skipped'; FinalOutcome = 'Skipped' } }
        'Failed' {
            if ($transient) { return @{ Status = 'InProgress'; FinalOutcome = $null } }
            return @{ Status = 'Failed'; FinalOutcome = 'Failed' }
        }
        default { return @{ Status = $status; FinalOutcome = $null } }
    }
}

function Invoke-AgentProvider {
    <#
        .SYNOPSIS
            Dispatches an on-prem target to its provider and returns the ProviderResult.
            Parity with provider selection in Worker.ProcessAsync.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] $Config,
        [hashtable] $LogProperties = @{}
    )
    $dryRun = [bool](Get-OptionalProp $Config 'DryRun')
    switch ($Target) {
        'ActiveDirectory' {
            return Remove-AdComputer -Context $Context -DryRun:$dryRun `
                -SearchRoot ([string](Get-OptionalProp $Config 'AdSearchRoot')) -LogProperties $LogProperties
        }
        'ConfigMgr' {
            $baseUrl = [string](Get-OptionalProp $Config 'SccmBaseUrl')
            if ([string]::IsNullOrWhiteSpace($baseUrl)) {
                return New-ProviderResult -Status 'Failed' -Detail 'ConfigMgr AdminService base URL not configured' -Transient
            }
            return Remove-SccmDevice -Context $Context -BaseUrl $baseUrl -DryRun:$dryRun `
                -Credential (Get-OptionalProp $Config 'SccmCredential') -LogProperties $LogProperties
        }
        'LicenseRemoval' {
            return Invoke-LicenseRemoval -Context $Context -Options (Get-OptionalProp $Config 'DeviceActions') `
                -DryRun:$dryRun -LogProperties $LogProperties
        }
        'BiosPasswordRemoval' {
            return Invoke-BiosPasswordRemoval -Context $Context -Options (Get-OptionalProp $Config 'DeviceActions') `
                -DryRun:$dryRun -LogProperties $LogProperties
        }
        default { return $null }
    }
}

function Invoke-OnPremAction {
    <#
        .SYNOPSIS
            Executes a single dispatched on-prem action end-to-end. Parity with Worker.ProcessAsync:
            load request -> find sub-action -> write-before-action audit -> run provider ->
            persist status -> write-after-action audit.
        .OUTPUTS
            [pscustomobject]@{ Handled; RequestId; Target; Status; Detail } — Handled=$false when
            the request/target/action is unknown (message is completed, nothing to do).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Message,
        [Parameter(Mandatory)] $Config,
        $Connection
    )
    $requestId = [string](Get-OptionalProp $Message 'RequestId')
    $target = [string](Get-OptionalProp $Message 'Target')
    $logProps = @{ requestId = $requestId; target = $target }

    if ($target -notin $script:OnPremTargets) {
        Write-AtLog -Level 'Warning' -Message "No on-prem provider for target '$target'" -Properties $logProps
        return [pscustomobject]@{ Handled = $false; RequestId = $requestId; Target = $target; Status = 'Ignored'; Detail = 'unknown target' }
    }

    $record = Get-DecommissionRequest -RequestId $requestId -Connection $Connection
    if ($null -eq $record) {
        Write-AtLog -Level 'Warning' -Message "Request $requestId not found in state store; ignoring" -Properties $logProps
        return [pscustomobject]@{ Handled = $false; RequestId = $requestId; Target = $target; Status = 'Ignored'; Detail = 'request not found' }
    }

    $actions = @(Get-OptionalProp $record 'actions')
    $action = $actions | Where-Object { [string](Get-OptionalProp $_ 'Target') -eq $target } | Select-Object -First 1
    if ($null -eq $action) {
        Write-AtLog -Level 'Warning' -Message "No $target sub-action on request $requestId" -Properties $logProps
        return [pscustomobject]@{ Handled = $false; RequestId = $requestId; Target = $target; Status = 'Ignored'; Detail = 'sub-action not found' }
    }

    $context = Get-AgentDeviceContext -Record $record

    # Write-before-action: record the attempt in the immutable audit.
    Add-AgentAudit -Record $record -Action 'DeleteAttempted' -Target $target -Outcome 'InProgress'

    $result = Invoke-AgentProvider -Target $target -Context $context -Config $Config -LogProperties $logProps
    $update = Get-AgentActionUpdate -Result $result
    Set-ActionStatus -RequestId $requestId -Target $target -Status $update.Status -FinalOutcome $update.FinalOutcome

    Add-AgentAudit -Record $record -Action 'DeleteCompleted' -Target $target `
        -Outcome $update.Status -Reason ([string](Get-OptionalProp $result 'Detail'))

    Write-AtLog -Message "On-prem $target for $requestId -> $($update.Status)" -Properties $logProps
    return [pscustomobject]@{
        Handled   = $true
        RequestId = $requestId
        Target    = $target
        Status    = $update.Status
        Detail    = [string](Get-OptionalProp $result 'Detail')
    }
}

function Add-AgentAudit {
    <# Appends a WORM audit record derived from the request row (actor=onprem-agent). Best-effort. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)][string] $Action,
        [string] $Target,
        [string] $Outcome,
        [string] $Reason
    )
    try {
        $audit = New-AuditRecord -RequestId ([string](Get-OptionalProp $Record 'RequestId')) `
            -Action $Action `
            -CorrelationId ([string](Get-OptionalProp $Record 'CorrelationId')) `
            -TicketNumber ([string](Get-OptionalProp $Record 'TicketNumber')) `
            -AssetId ([string](Get-OptionalProp $Record 'AssetId')) `
            -TargetEnvironment $Target -Actor 'onprem-agent' -Outcome $Outcome -Reason $Reason
        Add-AuditRecord -Record $audit | Out-Null
    }
    catch {
        Write-AtLog -Level 'Warning' -Message "Audit append failed: $($_.Exception.Message)" -Properties @{ requestId = (Get-OptionalProp $Record 'RequestId') }
    }
}

Export-ModuleMember -Function ConvertFrom-ActionDispatchMessage, Get-AgentDeviceContext, `
    Get-AgentActionUpdate, Invoke-AgentProvider, Invoke-OnPremAction, Add-AgentAudit
