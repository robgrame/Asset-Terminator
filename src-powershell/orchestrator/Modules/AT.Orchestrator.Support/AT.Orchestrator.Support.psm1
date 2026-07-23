# AT.Orchestrator.Support.psm1
# Orchestration glue + pure decision logic for the Durable orchestrator app.
# Parity with AssetTerminator.Orchestrator (DecommissionOrchestrator +
# DecommissionActivities + GraphDeviceEnricher + CallbackPublisher + DeviceContextFactory).

Set-StrictMode -Version Latest

# --- Target classification (parity with the orchestrator's private predicates) ---

function Test-IsObjectDeleteTarget {
    [CmdletBinding()] param([Parameter(Mandatory)][string] $Target)
    return $Target -in @('ActiveDirectory', 'ConfigMgr', 'Intune', 'EntraId')
}

function Test-IsObjectDeleteOrAutopilotTarget {
    [CmdletBinding()] param([Parameter(Mandatory)][string] $Target)
    return (Test-IsObjectDeleteTarget -Target $Target) -or $Target -eq 'Autopilot'
}

function Test-IsPreWipeGatingTarget {
    [CmdletBinding()] param([Parameter(Mandatory)][string] $Target)
    return $Target -in @('LicenseRemoval', 'BiosPasswordRemoval')
}

function Test-IsOnPremDeleteTarget {
    [CmdletBinding()] param([Parameter(Mandatory)][string] $Target)
    return $Target -in @('ActiveDirectory', 'ConfigMgr', 'LicenseRemoval', 'BiosPasswordRemoval')
}

function Test-IsTerminalActionStatus {
    [CmdletBinding()] param([Parameter(Mandatory)][string] $Status)
    return $Status -in @('Success', 'Skipped', 'Failed', 'Blocked', 'TimedOut')
}

# --- Aggregate state (parity with DecommissionActivities.OverallState) ---

function Get-OverallState {
    <#
        .SYNOPSIS
            Computes the overall request state from its action statuses. Parity with
            DecommissionActivities.OverallState.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Actions)
    $statuses = @($Actions | ForEach-Object { [string](Get-OptionalProp $_ 'status') })
    if ($statuses.Count -eq 0) { return 'Completed' }
    $allDone = @($statuses | Where-Object { $_ -notin @('Success', 'Skipped') }).Count -eq 0
    if ($allDone) { return 'Completed' }
    if (@($statuses | Where-Object { $_ -in @('Pending', 'InProgress') }).Count -gt 0) { return 'InProgress' }
    $anySuccess = @($statuses | Where-Object { $_ -eq 'Success' }).Count -gt 0
    $anyFailedOrBlocked = @($statuses | Where-Object { $_ -in @('Failed', 'Blocked') }).Count -gt 0
    if ($anySuccess -and $anyFailedOrBlocked) { return 'PartiallyCompleted' }
    $allFailed = @($statuses | Where-Object { $_ -ne 'Failed' }).Count -eq 0
    if ($allFailed) { return 'Failed' }
    return 'PartiallyCompleted'
}

function Get-ActionUpdateFromResult {
    <#
        .SYNOPSIS
            Maps a ProviderResult to the persisted action status/outcome. Parity with
            DecommissionActivities.ApplyResult: transient failures become InProgress so
            the poller retries; hard failures are final.
        .OUTPUTS
            @{ Status = <ActionStatus>; FinalOutcome = <string|null> }
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

function Get-PreWipeStatus {
    <#
        .SYNOPSIS
            Evaluates completion of the on-device pre-wipe actions. Parity with
            DecommissionActivities.CheckPreWipeActions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Actions,
        [datetime] $DueAtUtc,
        [datetime] $NowUtc = ([datetime]::UtcNow)
    )
    $allTerminal = @($Actions | Where-Object { -not (Test-IsTerminalActionStatus -Status ([string](Get-OptionalProp $_ 'status'))) }).Count -eq 0
    $allSucceeded = @($Actions | Where-Object { [string](Get-OptionalProp $_ 'status') -notin @('Success', 'Skipped') }).Count -eq 0
    $deadlinePassed = $false
    if ($PSBoundParameters.ContainsKey('DueAtUtc') -and $DueAtUtc) { $deadlinePassed = $NowUtc -ge $DueAtUtc }
    $failed = @($Actions | Where-Object { [string](Get-OptionalProp $_ 'status') -notin @('Success', 'Skipped') } | ForEach-Object {
            $d = Get-OptionalProp $_ 'details'; if (-not $d) { $d = [string](Get-OptionalProp $_ 'status') }
            "$(Get-OptionalProp $_ 'target'): $d"
        })
    return [pscustomobject]@{
        AllTerminal    = $allTerminal
        AllSucceeded   = $allSucceeded
        DeadlinePassed = $deadlinePassed
        FailedReasons  = @($failed)
    }
}

# --- Config binding ---

function Get-OrchestrationOptions {
    [CmdletBinding()] param()
    $pollSeconds = 300
    $raw = [Environment]::GetEnvironmentVariable('AssetTerminator__Orchestration__PreWipePollIntervalSeconds')
    $parsed = 0
    if (-not [string]::IsNullOrEmpty($raw) -and [int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) { $pollSeconds = $parsed }
    $require = $true
    $rr = [Environment]::GetEnvironmentVariable('AssetTerminator__PreWipe__RequireCompletionBeforeWipe')
    $rb = $false
    if (-not [string]::IsNullOrEmpty($rr) -and [bool]::TryParse($rr, [ref]$rb)) { $require = $rb }

    $baseSeconds = 10.0
    $bd = [Environment]::GetEnvironmentVariable('AssetTerminator__Orchestration__RetryBaseDelaySeconds')
    $bdp = 0.0
    if (-not [string]::IsNullOrEmpty($bd) -and [double]::TryParse($bd, [ref]$bdp) -and $bdp -gt 0) { $baseSeconds = $bdp }
    $maxSeconds = 3600.0
    $md = [Environment]::GetEnvironmentVariable('AssetTerminator__Orchestration__RetryMaxDelaySeconds')
    $mdp = 0.0
    if (-not [string]::IsNullOrEmpty($md) -and [double]::TryParse($md, [ref]$mdp) -and $mdp -gt 0) { $maxSeconds = $mdp }

    [pscustomobject]@{
        PreWipePollIntervalSeconds  = $pollSeconds
        RequireCompletionBeforeWipe = $require
        RetryBaseDelaySeconds       = $baseSeconds
        RetryMaxDelaySeconds        = $maxSeconds
    }
}

function Get-DefaultGuardrailConfig {
    <# Default guardrail config (parity with the shipped .NET defaults). #>
    [CmdletBinding()] param()
    [pscustomobject]@{
        guardrails = @(
            [pscustomobject]@{ name = 'Encryption'; enabled = $true; mode = 'Mandatory'; overridable = $true; settings = [pscustomobject]@{} },
            [pscustomobject]@{ name = 'Inactivity'; enabled = $true; mode = 'Mandatory'; overridable = $true; settings = [pscustomobject]@{ minimumInactiveDays = 30 } },
            [pscustomobject]@{ name = 'CriticalGroup'; enabled = $true; mode = 'Mandatory'; overridable = $true; settings = [pscustomobject]@{ BlockedGroups = 'Executives' } }
        )
    }
}

function Get-GuardrailConfig {
    <# Loads guardrail config from AssetTerminator__GuardrailsJson, else the default. #>
    [CmdletBinding()] param()
    $json = [Environment]::GetEnvironmentVariable('AssetTerminator__GuardrailsJson')
    if (-not [string]::IsNullOrWhiteSpace($json)) {
        try { return ($json | ConvertFrom-Json) } catch { Write-AtLog -Level 'Warning' -Message "Invalid GuardrailsJson; using defaults: $($_.Exception.Message)" }
    }
    return Get-DefaultGuardrailConfig
}

# --- Enrichment (parity with GraphDeviceEnricher) ---

function Get-EnrichedDeviceContext {
    <#
        .SYNOPSIS
            Resolves Intune + Entra + primary-user signals for a request record and
            returns the device context used by providers and guardrails.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Record)

    $ctx = New-DeviceContext -Record $Record
    # Guardrail-facing signals (defaults; overwritten by enrichment when available).
    $ctx | Add-Member -NotePropertyName 'isEncrypted' -NotePropertyValue $null -Force
    $ctx | Add-Member -NotePropertyName 'hasRecoveryKeyEscrowed' -NotePropertyValue $null -Force
    $ctx | Add-Member -NotePropertyName 'lastSyncDateTime' -NotePropertyValue $null -Force
    $ctx | Add-Member -NotePropertyName 'deviceCategoryDisplayName' -NotePropertyValue (Get-OptionalProp $Record 'assetCategory') -Force
    $ctx | Add-Member -NotePropertyName 'groupMemberships' -NotePropertyValue @() -Force
    $ctx | Add-Member -NotePropertyName 'primaryUserDisabled' -NotePropertyValue $false -Force

    $logProps = @{ requestId = (Get-OptionalProp $Record 'requestId'); deviceName = (Get-OptionalProp $Record 'deviceName') }

    try {
        $device = Get-IntuneManagedDevice -DeviceName (Get-OptionalProp $Record 'deviceName') `
            -SerialNumber (Get-OptionalProp $Record 'serialNumber') -LogProperties $logProps
        if ($device) {
            $ctx.IntuneDeviceId = $device.id
            if ($null -ne (Get-OptionalProp $device 'isEncrypted')) { $ctx.isEncrypted = [bool]$device.isEncrypted }
            $ctx.lastSyncDateTime = Get-OptionalProp $device 'lastSyncDateTime'
            $cat = Get-OptionalProp $device 'deviceCategoryDisplayName'; if ($cat) { $ctx.deviceCategoryDisplayName = $cat }
            # Parity note (matches GraphDeviceEnricher TODO): hasRecoveryKeyEscrowed would come
            # from /informationProtection/bitlocker/recoveryKeys (BitlockerKey.Read.All) and
            # groupMemberships from the Entra /memberOf endpoint; both are left as defaults so a
            # custom guardrail can opt in without changing the pipeline.
        }
    }
    catch { Write-AtLog -Level 'Warning' -Message "Intune enrichment failed: $($_.Exception.Message)" -Properties $logProps }

    try {
        $entraId = Resolve-EntraDeviceObjectId -Context $ctx
        if ($entraId) { $ctx.EntraDeviceId = $entraId }
    }
    catch { Write-AtLog -Level 'Warning' -Message "Entra enrichment failed: $($_.Exception.Message)" -Properties $logProps }

    $upn = Get-OptionalProp $Record 'primaryUserUpn'
    if ($upn) {
        try {
            $user = Invoke-GraphRequest -Method GET -Path "users/$([Uri]::EscapeDataString($upn))?`$select=accountEnabled"
            if ($user -and $null -ne (Get-OptionalProp $user 'accountEnabled')) { $ctx.primaryUserDisabled = (-not [bool]$user.accountEnabled) }
        }
        catch { Write-AtLog -Level 'Warning' -Message "Primary-user enrichment failed: $($_.Exception.Message)" -Properties $logProps }
    }

    return $ctx
}

# --- Callback publishing (parity with CallbackPublisher.PublishAsync) ---

function Publish-Callback {
    <#
        .SYNOPSIS
            Builds + sends a ServiceNow callback from the current record, mirrors it to
            the audit and telemetry. Best-effort: failures are logged, not thrown.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Record, [Parameter(Mandatory)][string] $EventType)

    $actions = @(Get-OptionalProp $Record 'actions') | ForEach-Object {
        [pscustomobject]@{
            target     = Get-OptionalProp $_ 'Target'
            action     = Get-OptionalProp $_ 'Action'
            status     = [string](Get-OptionalProp $_ 'Status')
            retryCount = Get-OptionalProp $_ 'Attempts'
            details    = Get-OptionalProp $_ 'FinalOutcome'
        }
    }
    $callback = New-ServiceNowCallback -RequestId (Get-OptionalProp $Record 'RequestId') `
        -OverallStatus ([string](Get-OptionalProp $Record 'State')) -CorrelationId (Get-OptionalProp $Record 'CorrelationId') `
        -Detail $EventType -Actions @($actions)

    try {
        Add-AuditRecord -Record (New-AuditRecord -CorrelationId (Get-OptionalProp $Record 'CorrelationId') `
                -RequestId (Get-OptionalProp $Record 'RequestId') -TicketNumber (Get-OptionalProp $Record 'TicketNumber') `
                -AssetId (Get-OptionalProp $Record 'AssetId') -Action 'CallbackSent' -Actor 'system' `
                -Outcome ([string](Get-OptionalProp $Record 'State')) -Reason $EventType)
    }
    catch { Write-AtLog -Level 'Warning' -Message "Callback audit failed: $($_.Exception.Message)" }

    try { Send-ServiceNowCallback -Callback $callback }
    catch { Write-AtLog -Level 'Warning' -Message "Callback send failed: $($_.Exception.Message)" }
}

function Get-StoredDeviceContext {
    <# Returns the enriched device context stored on the record, or a fresh one. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Record)
    $json = Get-OptionalProp $Record 'DeviceContextJson'
    if (-not $json) { $json = Get-OptionalProp $Record 'deviceContextJson' }
    if ($json) {
        try { return ($json | ConvertFrom-Json) } catch { }
    }
    return New-DeviceContext -Record $Record
}

function Invoke-CloudDelete {
    <#
        .SYNOPSIS
            Executes a cloud object-delete for a target and normalizes the result to
            @{ Status; Detail; Transient }. Honours -DryRun via the providers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)] $Context,
        [switch] $DryRun,
        [hashtable] $LogProperties = @{}
    )
    switch ($Target) {
        'EntraId' {
            $r = Remove-EntraDevice -Context $Context -DryRun:$DryRun -LogProperties $LogProperties
            return [pscustomobject]@{ Status = $r.Status; Detail = $r.Detail; Transient = [bool]$r.Transient }
        }
        'Intune' {
            $id = Get-OptionalProp $Context 'IntuneDeviceId'
            if (-not $id) { return [pscustomobject]@{ Status = 'Skipped'; Detail = 'not present in Intune'; Transient = $false } }
            $r = Remove-IntuneManagedDevice -ManagedDeviceId $id -DryRun:$DryRun -LogProperties $LogProperties
            $status = switch ($r.Outcome) { 'Deleted' { 'Success' } 'DryRun' { 'Skipped' } default { 'Failed' } }
            return [pscustomobject]@{ Status = $status; Detail = "Intune managedDevice $($r.Outcome)"; Transient = $false }
        }
        'Autopilot' {
            $serial = Get-OptionalProp $Context 'SerialNumber'
            $r = Remove-AutopilotDevice -SerialNumber $serial -DryRun:$DryRun -LogProperties $LogProperties
            $status = switch ($r.Outcome) { 'Deleted' { 'Success' } { $_ -in @('DryRun', 'Skipped', 'NotFound') } { 'Skipped' } default { 'Failed' } }
            return [pscustomobject]@{ Status = $status; Detail = $r.Detail; Transient = $false }
        }
        default {
            return [pscustomobject]@{ Status = 'Failed'; Detail = "no cloud provider for target '$Target'"; Transient = $false }
        }
    }
}

function Add-RequestAudit {
    <# Appends a WORM audit record derived from the request row. Best-effort. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)][string] $Action,
        [string] $Outcome,
        [string] $Target,
        [string] $Reason,
        $GuardrailResults
    )
    try {
        $rec = New-AuditRecord -CorrelationId (Get-OptionalProp $Record 'CorrelationId') `
            -RequestId (Get-OptionalProp $Record 'RequestId') -TicketNumber (Get-OptionalProp $Record 'TicketNumber') `
            -AssetId (Get-OptionalProp $Record 'AssetId') -Action $Action -Actor 'system' -Outcome $Outcome `
            -TargetEnvironment $Target -Reason $Reason -GuardrailResults $GuardrailResults
        Add-AuditRecord -Record $rec
    }
    catch { Write-AtLog -Level 'Warning' -Message "Audit append failed: $($_.Exception.Message)" }
}

# --- Reconciliation (parity with ReconciliationService) ---

function Get-ReconcileBackoffSeconds {
    <#
        .SYNOPSIS
            Exponential backoff (seconds) for a retry count: Base * 2^min(retry,20),
            capped at Max. Parity with ReconciliationService.ComputeBackoff.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int] $RetryCount, [double] $BaseSeconds = 10.0, [double] $MaxSeconds = 3600.0)
    $exp = [Math]::Min([Math]::Max($RetryCount, 0), 20)
    $delay = $BaseSeconds * [Math]::Pow(2, $exp)
    if ($delay -gt $MaxSeconds) { return $MaxSeconds }
    return $delay
}

function Get-ReconcileActionDecision {
    <#
        .SYNOPSIS
            Decides how to persist a reconciled action from a live provider status result.
            Parity with ReconciliationService.ReconcileActionAsync: success is terminal;
            hard failures are terminal; transient / not-yet-complete retries with backoff
            until MaxRetries, then fails.
        .OUTPUTS
            @{ Status; FinalOutcome; Detail; NewRetryCount; BackoffSeconds; Terminal }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Result,
        [int] $RetryCount = 0,
        [int] $MaxRetries = 10,
        [double] $BackoffBaseSeconds = 10.0,
        [double] $BackoffMaxSeconds = 3600.0
    )
    $status = [string](Get-OptionalProp $Result 'Status')
    $detail = [string](Get-OptionalProp $Result 'Detail')
    $transient = [bool](Get-OptionalProp $Result 'Transient')

    if ($status -eq 'Success') {
        return [pscustomobject]@{
            Status = 'Success'; FinalOutcome = 'Success'; Detail = ($detail ? $detail : 'completed')
            NewRetryCount = $RetryCount; BackoffSeconds = $null; Terminal = $true
        }
    }

    $newRetry = $RetryCount + 1
    if (-not $transient -and $status -eq 'Failed') {
        return [pscustomobject]@{
            Status = 'Failed'; FinalOutcome = 'Failed'; Detail = $detail
            NewRetryCount = $newRetry; BackoffSeconds = $null; Terminal = $true
        }
    }
    if ($newRetry -ge $MaxRetries) {
        return [pscustomobject]@{
            Status = 'Failed'; FinalOutcome = 'Failed'; Detail = "max retries ($MaxRetries) exceeded: $detail"
            NewRetryCount = $newRetry; BackoffSeconds = $null; Terminal = $true
        }
    }
    $backoff = Get-ReconcileBackoffSeconds -RetryCount $newRetry -BaseSeconds $BackoffBaseSeconds -MaxSeconds $BackoffMaxSeconds
    return [pscustomobject]@{
        Status = 'InProgress'; FinalOutcome = $null; Detail = ($detail ? $detail : 'pending')
        NewRetryCount = $newRetry; BackoffSeconds = $backoff; Terminal = $false
    }
}

function Invoke-ProviderStatus {
    <#
        .SYNOPSIS
            Fetches the live status for an action target during reconciliation, normalized
            to @{ Status; Detail; Transient }. Returns $null for on-prem targets with no
            in-host provider (owned by the agent — the reconciler waits).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Target, [Parameter(Mandatory)] $Context, [hashtable] $LogProperties = @{})
    switch ($Target) {
        'Wipe' { return Get-IntuneWipeStatus -Context $Context -LogProperties $LogProperties }
        'Retire' { return Get-IntuneRetireStatus -Context $Context -LogProperties $LogProperties }
        'Intune' { return Get-IntuneDeleteStatus -Context $Context -LogProperties $LogProperties }
        'EntraId' {
            $r = Get-EntraDeviceStatus -Context $Context
            return [pscustomobject]@{ Status = $r.Status; Detail = $r.Detail; Transient = [bool](Get-OptionalProp $r 'Transient') }
        }
        'Autopilot' { return [pscustomobject]@{ Status = 'Success'; Detail = 'autopilot delete reconciled'; Transient = $false } }
        default { return $null }
    }
}

function Invoke-RequestReconcile {
    <#
        .SYNOPSIS
            Reconciles one active request: enforces the give-up timeout, re-checks each
            outstanding action with retry-backoff, updates SLA + overall state, and pushes
            callbacks on meaningful changes. Parity with ReconciliationService.ReconcileAsync.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Record,
        [datetime] $NowUtc = ([datetime]::UtcNow),
        [hashtable] $SlaConfig = (Get-DefaultSlaConfig)
    )
    $requestId = [string](Get-OptionalProp $Record 'RequestId')
    $category = [string](Get-OptionalProp $Record 'AssetCategory')
    $prevState = [string](Get-OptionalProp $Record 'State')
    $prevSla = [string](Get-OptionalProp $Record 'SlaState')
    $dueAt = Get-OptionalProp $Record 'DueAtUtc'

    # --- Give-up / timeout ---
    if ($dueAt -and $NowUtc -ge [datetime]$dueAt) {
        foreach ($a in @($Record.actions)) {
            $st = [string](Get-OptionalProp $a 'Status')
            if (-not (Test-IsTerminalActionStatus -Status $st)) {
                Set-ActionStatus -RequestId $requestId -Target ([string](Get-OptionalProp $a 'Target')) -Status 'TimedOut' -FinalOutcome 'TimedOut'
                Set-ActionNextPoll -RequestId $requestId -Target ([string](Get-OptionalProp $a 'Target'))
            }
        }
        Set-RequestState -RequestId $requestId -State 'TimedOut'
        Add-RequestAudit -Record $Record -Action 'RequestTimedOut' -Outcome 'TimedOut' -Reason "exceeded max duration (due $dueAt)"
        $fresh = Get-DecommissionRequest -RequestId $requestId
        if ($fresh) { Publish-Callback -Record $fresh -EventType 'TimedOut' }
        return
    }

    $slaState = Get-SlaState -Category $category -CreatedAtUtc ([datetime](Get-OptionalProp $Record 'CreatedAtUtc')) -NowUtc $NowUtc -Config $SlaConfig
    $maxRetries = if ($SlaConfig.ContainsKey($category)) { [int]$SlaConfig[$category].MaxRetries } else { 10 }
    $opts = Get-OrchestrationOptions
    $context = Get-StoredDeviceContext -Record $Record

    foreach ($a in @($Record.actions)) {
        $st = [string](Get-OptionalProp $a 'Status')
        if (Test-IsTerminalActionStatus -Status $st) { continue }
        $target = [string](Get-OptionalProp $a 'Target')
        $nextPoll = Get-OptionalProp $a 'NextPollUtc'
        if ($nextPoll -and ([datetime]$nextPoll) -gt $NowUtc) { continue } # still backing off

        $result = Invoke-ProviderStatus -Target $target -Context $context -LogProperties @{ requestId = $requestId; target = $target }
        if ($null -eq $result) { continue } # on-prem: owned by the agent

        $attempts = [int](Get-OptionalProp $a 'Attempts')
        $decision = Get-ReconcileActionDecision -Result $result -RetryCount $attempts -MaxRetries $maxRetries `
            -BackoffBaseSeconds $opts.RetryBaseDelaySeconds -BackoffMaxSeconds $opts.RetryMaxDelaySeconds

        Set-ActionStatus -RequestId $requestId -Target $target -Status $decision.Status -FinalOutcome $decision.FinalOutcome
        if ($decision.Terminal) {
            Set-ActionNextPoll -RequestId $requestId -Target $target
            $auditAction = ($decision.Status -eq 'Success') ? 'ActionCompleted' : 'ActionFailed'
            Add-RequestAudit -Record $Record -Action $auditAction -Target $target -Outcome $decision.Status -Reason $decision.Detail
        }
        else {
            Set-ActionNextPoll -RequestId $requestId -Target $target -NextPollUtc $NowUtc.AddSeconds($decision.BackoffSeconds)
        }
    }

    $fresh = Get-DecommissionRequest -RequestId $requestId
    $newState = if ($prevState -eq 'GuardrailsFailed') { 'GuardrailsFailed' } else { Get-OverallState -Actions @($fresh.actions) }
    Set-RequestState -RequestId $requestId -State $newState -SlaState $slaState

    $final = Get-DecommissionRequest -RequestId $requestId
    if ($newState -ne $prevState) {
        Publish-Callback -Record $final -EventType 'StateChanged'
    }
    elseif ($slaState -ne $prevSla -and $slaState -ne 'WithinSla') {
        Add-RequestAudit -Record $final -Action 'SlaStateChanged' -Outcome $slaState
        Publish-Callback -Record $final -EventType (($slaState -eq 'Breached') ? 'SlaBreached' : 'SlaAtRisk')
    }
}

function Invoke-ReconcileAll {
    <# Reconciles all active (non-terminal) requests. Parity with ReconcileAllAsync. #>
    [CmdletBinding()]
    param([int] $Max = 200)
    $active = @(Get-ActiveRequests -Max $Max)
    Write-AtLog -Message "Reconciling $($active.Count) active requests"
    foreach ($r in $active) {
        $id = [string](Get-OptionalProp $r 'RequestId')
        $full = Get-DecommissionRequest -RequestId $id
        if (-not $full) { continue }
        try { Invoke-RequestReconcile -Record $full }
        catch { Write-AtLog -Level 'Warning' -Message "Reconcile failed for ${id}: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function Test-IsObjectDeleteTarget, Test-IsObjectDeleteOrAutopilotTarget, `
    Test-IsPreWipeGatingTarget, Test-IsOnPremDeleteTarget, Test-IsTerminalActionStatus, `
    Get-OverallState, Get-ActionUpdateFromResult, Get-PreWipeStatus, Get-OrchestrationOptions, `
    Get-DefaultGuardrailConfig, Get-GuardrailConfig, Get-EnrichedDeviceContext, Publish-Callback, `
    Get-StoredDeviceContext, Invoke-CloudDelete, Add-RequestAudit, `
    Get-ReconcileBackoffSeconds, Get-ReconcileActionDecision, Invoke-ProviderStatus, `
    Invoke-RequestReconcile, Invoke-ReconcileAll
