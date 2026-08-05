#Requires -Version 7.6

# Translates one canonical intake payload into one Automation runbook job, and
# provides the durable claim/retry primitives JobMonitor uses to reconcile any
# request that did not finish dispatching inline (crash recovery, ambiguous
# ARM responses, throttling, ...).
#
# Design summary (see docs/flusso-alto-livello.md for the full narrative):
#   - WipeIntake persists the full canonical payload with status=Accepted
#     *before* attempting anything (durable handoff / write-before-action).
#     The immediate dispatch attempt that follows is an optimisation, not a
#     requirement for correctness: if it does not happen, or does not finish,
#     JobMonitor will.
#   - Every dispatch attempt - whether inline from WipeIntake or reconciled by
#     JobMonitor - first claims the row with an ETag-conditional MERGE, so two
#     workers can never both start the same runbook job.
#   - A deterministic job name (the requestId) makes the ARM PUT itself
#     idempotent; Invoke-IdempotentRunbookDispatch (AT.Automation) adds the
#     GET-before/GET-after checks that keep a timeout/429/5xx from ever being
#     misread as a clean failure or a clean success.
#   - Attempts are bounded: after DISPATCH_MAX_ATTEMPTS the request is failed
#     terminally (DispatchFailed) instead of retrying forever.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/AT.Common.psm1"
Import-Module "$PSScriptRoot/AT.State.psm1"
Import-Module "$PSScriptRoot/AT.Automation.psm1"

function Get-DispatchMaxAttempts {
    return Get-AppSettingInt -Name 'DISPATCH_MAX_ATTEMPTS' -Default 8
}

function Get-DispatchBackoffBaseSeconds {
    return Get-AppSettingInt -Name 'DISPATCH_BACKOFF_BASE_SECONDS' -Default 20
}

function Get-DispatchBackoffMaxSeconds {
    return Get-AppSettingInt -Name 'DISPATCH_BACKOFF_MAX_SECONDS' -Default 1800
}

function Get-DispatchMaxConcurrency {
    return Get-AppSettingInt -Name 'DISPATCH_MAX_CONCURRENCY' -Default 10
}

function Get-EvidenceMaxAttempts {
    return Get-AppSettingInt -Name 'EVIDENCE_MAX_ATTEMPTS' -Default 5
}

function Get-CallbackMaxAttempts {
    return Get-AppSettingInt -Name 'CALLBACK_MAX_ATTEMPTS' -Default 6
}

function Get-CallbackBackoffBaseSeconds {
    return Get-AppSettingInt -Name 'CALLBACK_BACKOFF_BASE_SECONDS' -Default 15
}

function Get-CallbackBackoffMaxSeconds {
    return Get-AppSettingInt -Name 'CALLBACK_BACKOFF_MAX_SECONDS' -Default 900
}

function Get-CallbackMaxConcurrency {
    return Get-AppSettingInt -Name 'CALLBACK_MAX_CONCURRENCY' -Default 20
}

function Set-CallbackPending {
    <#
    .SYNOPSIS
        Arms the durable callback pipeline for a request that just reached a
        terminal state (Completed, PartiallyCompleted, Failed or DispatchFailed
        - dry runs included). Does nothing when the request has no callbackUrl.
    .DESCRIPTION
        Sets callbackStatus='Pending' and assigns a stable eventId the first
        time a terminal state is reached, so every callback delivery attempt
        for this outcome - however many retries it takes - carries the same
        requestId/eventId pair for the receiver's own idempotency check.
    .OUTPUTS
        The eventId used, or $null when no callback is configured.
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestId,
        [string] $CallbackUrl,
        [string] $ExistingEventId
    )

    if ([string]::IsNullOrWhiteSpace($CallbackUrl)) { return $null }

    $eventId = if ([string]::IsNullOrWhiteSpace($ExistingEventId)) { [guid]::NewGuid().ToString() } else { $ExistingEventId }

    Update-WipeRequestState -Platform $Platform -RequestId $RequestId -Properties @{
        callbackStatus   = 'Pending'
        callbackAttempts = 0
        eventId          = $eventId
    }

    return $eventId
}

# ---------------------------------------------------------------------------
# Reconciliation candidate discovery (JobMonitor's dispatch pass)
# ---------------------------------------------------------------------------
function Get-DispatchCandidateRequests {
    <#
    .SYNOPSIS
        Requests still waiting for a durable dispatch outcome: freshly accepted
        (never attempted) or mid-retry after a prior ambiguous/transient
        failure. Ordering/limiting to a bounded concurrency happens in
        Get-DueDispatchCandidates so one JobMonitor tick never tries to claim
        an unbounded number of rows.
    #>
    param([int] $Top = 200)
    return @(Find-WipeRequestState -Filter "status eq 'Accepted' or status eq 'Dispatching'" -Top $Top)
}

function Test-BackoffFieldDue {
    <#
    .SYNOPSIS
        Generic backoff check shared by the dispatch and callback reconciliation
        passes: true when the named datetime field is absent, unparsable, or in
        the past.
    #>
    param($Request, [Parameter(Mandatory)] [string] $FieldName)

    $hasField = $Request.PSObject.Properties.Name -contains $FieldName -and $Request.$FieldName
    if (-not $hasField) { return $true }

    $next = $null
    if (-not [datetime]::TryParse([string]$Request.$FieldName, [ref] $next)) { return $true }
    return (Get-Date).ToUniversalTime() -ge $next.ToUniversalTime()
}

function Test-DispatchAttemptDue {
    <#
    .SYNOPSIS
        True when a candidate request has no scheduled backoff yet, or its
        backoff window has elapsed.
    #>
    param($Request)
    return Test-BackoffFieldDue -Request $Request -FieldName 'nextAttemptAt'
}

function Get-DueDispatchCandidates {
    <#
    .SYNOPSIS
        Candidate requests whose backoff window has elapsed, capped at the
        configured dispatch concurrency limit so a single JobMonitor tick
        cannot overwhelm the Automation account with simultaneous ARM PUTs.
    #>
    param([int] $MaxConcurrency = -1)

    if ($MaxConcurrency -lt 0) { $MaxConcurrency = Get-DispatchMaxConcurrency }
    $candidates = @(Get-DispatchCandidateRequests | Where-Object { Test-DispatchAttemptDue -Request $_ })
    return @($candidates | Select-Object -First $MaxConcurrency)
}

# ---------------------------------------------------------------------------
# Atomic claim
# ---------------------------------------------------------------------------
function Invoke-DispatchClaim {
    <#
    .SYNOPSIS
        Atomically claims one request row for a dispatch attempt using an
        ETag-conditional MERGE. Two callers racing for the same row (a second
        JobMonitor tick, or JobMonitor racing WipeIntake's own inline attempt)
        can never both win: the loser's MERGE is rejected with HTTP 412 and it
        simply moves on to the next candidate.
    .OUTPUTS
        PSCustomObject: Claimed (bool), Reason, Entity (the pre-claim entity).
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [string] $RequestId
    )

    $current = Get-WipeRequestStateWithETag -Platform $Platform -RequestId $RequestId
    if (-not $current) {
        return [pscustomobject]@{ Claimed = $false; Reason = 'NotFound'; Entity = $null }
    }
    if ([string]$current.Entity.status -notin @('Accepted', 'Dispatching')) {
        return [pscustomobject]@{ Claimed = $false; Reason = 'NotEligible'; Entity = $current.Entity }
    }

    $claimed = Set-WipeRequestStateClaim -Platform $Platform -RequestId $RequestId -ETag $current.ETag -Properties @{
        status        = 'Dispatching'
        claimedAt     = (Get-Date).ToUniversalTime()
        lastAttemptAt = (Get-Date).ToUniversalTime()
    }

    if (-not $claimed) {
        return [pscustomobject]@{ Claimed = $false; Reason = 'ClaimConflict'; Entity = $current.Entity }
    }

    return [pscustomobject]@{ Claimed = $true; Reason = ''; Entity = $current.Entity }
}

function ConvertTo-DispatchMessage {
    <#
    .SYNOPSIS
        Rebuilds the canonical dispatch payload from a durably persisted state
        row (the 'payloadJson' property written by WipeIntake at Accepted
        time). This is what lets JobMonitor redispatch a request after a
        Function App restart without ever holding the original HTTP payload
        in memory.
    #>
    param($Entity)

    $payloadJson = Get-JsonPropertyValue -InputObject $Entity -Name 'payloadJson'
    if ([string]::IsNullOrWhiteSpace([string]$payloadJson)) {
        throw "Request row for '$($Entity.RowKey)' has no persisted payloadJson; cannot reconstruct the dispatch message."
    }
    return ([string]$payloadJson | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Dispatch attempt (used both by WipeIntake's optional immediate attempt and
# by JobMonitor's reconciliation pass, always AFTER Invoke-DispatchClaim)
# ---------------------------------------------------------------------------
function Invoke-DisposalDispatch {
    <#
    .SYNOPSIS
        Performs one dispatch attempt for an already-claimed request: resolves
        the runbook binding, calls ARM through the ambiguity-safe helper, and
        persists the outcome. Never throws for a dispatch-side failure: every
        outcome (Dispatched, retryable Dispatching-with-backoff, or terminal
        DispatchFailed once attempts are exhausted) is returned and persisted.
    .OUTPUTS
        PSCustomObject: Status ('Completed'|'Dispatched'|'Dispatching'|'DispatchFailed'),
        ErrorMessage, AutomationJobName, AutomationJobId, Attempt, Terminal (bool),
        ReleaseLease (bool - true once the request reaches ANY terminal state).
    #>
    param(
        [Parameter(Mandatory)] $Message,
        [Parameter(Mandatory)] [string] $ExpectedPlatform,
        [int] $Attempt = 1,
        [int] $MaxAttempts = -1
    )

    if ($MaxAttempts -lt 0) { $MaxAttempts = Get-DispatchMaxAttempts }

    $payload = ConvertFrom-JsonBody -Body $Message
    if (-not $payload) { throw 'Dispatch payload body is not valid JSON.' }

    $requestId = [string]$payload.requestId
    $platform = [string]$payload.platform

    if ([string]::IsNullOrWhiteSpace($requestId)) { throw 'Message is missing requestId.' }
    if ($platform -ne $ExpectedPlatform) {
        throw "Message platform '$platform' does not match the expected platform '$ExpectedPlatform'."
    }

    $dryRunValue = Resolve-JsonPath -InputObject $payload -Path '$.options.dryRun'
    if ($null -eq $dryRunValue) { throw 'Message is missing options.dryRun.' }
    try {
        # Never cast a string directly to [bool]: in PowerShell [bool]'false' is
        # true because every non-empty string is truthy.
        $isDryRun = [System.Convert]::ToBoolean($dryRunValue)
    }
    catch {
        throw "Message options.dryRun must be a boolean, received '$dryRunValue'."
    }

    $callbackUrl = [string](Get-JsonPropertyValue -InputObject $payload -Name 'callbackUrl')

    $logProps = @{
        requestId     = $requestId
        correlationId = [string]$payload.correlationId
        platform      = $platform
        scenario      = [string]$payload.scenario
        serialNumber  = [string]$payload.device.serialNumber
        dryRun        = $isDryRun
        attempt       = $Attempt
    }

    Write-AtLog -Level 'Information' -Message 'Dispatching disposal request.' -Properties $logProps
    Write-AtAudit -Action 'WipeDispatchStarted' -Properties $logProps

    # Retirement never removes the device from its enrollment platform. Until the
    # runbooks accept a -Scenario parameter, a retirement request must not be sent
    # to a runbook whose first action is the unenrollment. This is a static
    # configuration problem: retrying will never fix it, so it fails terminally
    # on the first attempt rather than consuming the retry budget.
    if (-not [bool]$payload.options.removeFromEnrollmentPlatform -and
        -not (Get-AppSettingBool -Name 'RUNBOOKS_SUPPORT_SCENARIO' -Default $false)) {
        $reason = 'Retirement scenario requires runbooks that support -Scenario; set RUNBOOKS_SUPPORT_SCENARIO=true once updated.'
        Write-AtLog -Level 'Warning' -Message $reason -Properties $logProps
        Write-AtAudit -Action 'WipeDispatchFailed' -Level 'Error' -Properties ($logProps + @{ status = 'DispatchFailed'; error = $reason })
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'DispatchFailed'; errorMessage = $reason; completedAt = (Get-Date).ToUniversalTime(); attempts = $Attempt
        }
        Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl ($callbackUrl) | Out-Null
        return [pscustomobject]@{
            Status = 'DispatchFailed'; ErrorMessage = $reason; AutomationJobName = $null; AutomationJobId = $null
            Attempt = $Attempt; Terminal = $true; ReleaseLease = $true
        }
    }

    try {
        $binding = Resolve-RunbookBinding -Platform $platform -Message $payload
    }
    catch {
        # A misconfigured RUNBOOK_MAP is also a static problem: fail terminally.
        $reason = "Unable to resolve the runbook binding: $($_.Exception.Message)"
        Write-AtLog -Level 'Error' -Message $reason -Properties $logProps
        Write-AtAudit -Action 'WipeDispatchFailed' -Level 'Error' -Properties ($logProps + @{ status = 'DispatchFailed'; error = $reason })
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'DispatchFailed'; errorMessage = $reason; completedAt = (Get-Date).ToUniversalTime(); attempts = $Attempt
        }
        Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl ($callbackUrl) | Out-Null
        return [pscustomobject]@{
            Status = 'DispatchFailed'; ErrorMessage = $reason; AutomationJobName = $null; AutomationJobId = $null
            Attempt = $Attempt; Terminal = $true; ReleaseLease = $true
        }
    }

    # Idempotent job name: replaying the message returns the existing job.
    $jobName = $requestId

    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        status            = 'Dispatching'
        runbook           = $binding.Runbook
        timeoutMinutes    = $binding.TimeoutMinutes
        automationJobName = $jobName
        attempts          = $Attempt
        lastAttemptAt     = (Get-Date).ToUniversalTime()
    }

    if ($isDryRun) {
        Write-AtLog -Level 'Information' -Message 'Dry run: runbook not started.' -Properties $logProps
        Write-AtAudit -Action 'WipeDryRunCompleted' -Properties ($logProps + @{ status = 'Completed'; runbook = $binding.Runbook })
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'Completed'
            completedAt = (Get-Date).ToUniversalTime()
            resultJson = @{ dryRun = $true; runbook = $binding.Runbook; parameters = $binding.Parameters }
        }
        Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl ($callbackUrl) | Out-Null
        return [pscustomobject]@{
            Status = 'Completed'; ErrorMessage = ''; AutomationJobName = $null; AutomationJobId = $null
            Attempt = $Attempt; Terminal = $true; ReleaseLease = $true
        }
    }

    $dispatch = Invoke-IdempotentRunbookDispatch -JobName $jobName -Runbook $binding.Runbook `
        -Parameters $binding.Parameters -RunOn $binding.RunOn

    if ($dispatch.Outcome -eq 'Started') {
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status            = 'Dispatched'
            automationJobName = [string]$dispatch.Job.JobName
            automationJobId   = [string]$dispatch.Job.JobId
            dispatchedAt      = (Get-Date).ToUniversalTime()
            errorMessage      = ''
            dispatchOutcome   = 'Started'
        }
        $logProps.automationJobName = [string]$dispatch.Job.JobName
        Write-AtLog -Level 'Information' -Message 'Runbook job started.' -Properties $logProps
        Write-AtAudit -Action 'WipeJobStarted' -Properties ($logProps + @{ status = 'Dispatched'; runbook = $binding.Runbook; automationJobId = [string]$dispatch.Job.JobId })

        return [pscustomobject]@{
            Status = 'Dispatched'; ErrorMessage = ''
            AutomationJobName = [string]$dispatch.Job.JobName; AutomationJobId = [string]$dispatch.Job.JobId
            Attempt = $Attempt; Terminal = $false; ReleaseLease = $false
        }
    }

    # Outcome is PermanentFailure, ConfirmedAbsent or Unknown: never mark the
    # request DispatchFailed - and never release the device lease - while
    # attempts remain. 'Unknown' in particular must not be retried blindly
    # (the previous PUT might still land); the next attempt starts, as always,
    # with a fresh GET, so it self-corrects once ARM's state settles.
    $exhausted = $Attempt -ge $MaxAttempts

    if (-not $exhausted) {
        $delay = Get-BackoffDelaySeconds -Attempt $Attempt -BaseSeconds (Get-DispatchBackoffBaseSeconds) -MaxSeconds (Get-DispatchBackoffMaxSeconds)
        $nextAttemptAt = (Get-Date).ToUniversalTime().AddSeconds($delay)

        Write-AtLog -Level 'Warning' -Message "Dispatch attempt $Attempt/$MaxAttempts inconclusive ($($dispatch.Outcome)): $($dispatch.ErrorMessage). Retrying at $($nextAttemptAt.ToString('o'))." -Properties $logProps
        Write-AtAudit -Action 'WipeDispatchRetryScheduled' -Level 'Warning' -Properties ($logProps + @{ status = 'Dispatching'; dispatchOutcome = $dispatch.Outcome; nextAttemptAt = $nextAttemptAt.ToString('o') })

        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status          = 'Dispatching'
            errorMessage    = $dispatch.ErrorMessage
            dispatchOutcome = $dispatch.Outcome
            nextAttemptAt   = $nextAttemptAt
        }

        return [pscustomobject]@{
            Status = 'Dispatching'; ErrorMessage = $dispatch.ErrorMessage
            AutomationJobName = $jobName; AutomationJobId = $null
            Attempt = $Attempt; Terminal = $false; ReleaseLease = $false
        }
    }

    $terminalReason = if ($dispatch.Outcome -eq 'Unknown') {
        "Dispatch outcome could not be confirmed after $Attempt attempts (last: $($dispatch.ErrorMessage)). Manual verification of Automation job '$jobName' is required before assuming the device was not actioned."
    }
    else {
        "Dispatch failed after $Attempt attempts ($($dispatch.Outcome)): $($dispatch.ErrorMessage)"
    }

    Write-AtLog -Level 'Error' -Message $terminalReason -Properties $logProps
    Write-AtAudit -Action 'WipeDispatchFailed' -Level 'Error' -Properties ($logProps + @{ status = 'DispatchFailed'; dispatchOutcome = $dispatch.Outcome; error = $terminalReason })

    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        status          = 'DispatchFailed'
        errorMessage     = $terminalReason
        dispatchOutcome  = $dispatch.Outcome
        completedAt      = (Get-Date).ToUniversalTime()
        attempts         = $Attempt
    }
    Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl ($callbackUrl) | Out-Null

    return [pscustomobject]@{
        Status = 'DispatchFailed'; ErrorMessage = $terminalReason
        AutomationJobName = $jobName; AutomationJobId = $null
        Attempt = $Attempt; Terminal = $true; ReleaseLease = $true
    }
}

function Invoke-DispatchReconciliation {
    <#
    .SYNOPSIS
        End-to-end reconciliation of one candidate request row for JobMonitor:
        claim -> rebuild the canonical message from the durable payload ->
        attempt dispatch. Skips the row cleanly (Claimed=$false) when another
        worker already owns it.
    #>
    param([Parameter(Mandatory)] $Request)

    $platform = [string]$Request.PartitionKey
    $requestId = [string]$Request.RowKey

    $claim = Invoke-DispatchClaim -Platform $platform -RequestId $requestId
    if (-not $claim.Claimed) {
        return [pscustomobject]@{ Claimed = $false; Reason = $claim.Reason; Result = $null }
    }

    $priorAttempts = 0
    if ($claim.Entity.PSObject.Properties.Name -contains 'attempts' -and $claim.Entity.attempts) {
        [int]::TryParse([string]$claim.Entity.attempts, [ref] $priorAttempts) | Out-Null
    }
    $attempt = $priorAttempts + 1

    try {
        $message = ConvertTo-DispatchMessage -Entity $claim.Entity
    }
    catch {
        Write-AtLog -Level 'Error' -Message "JobMonitor: cannot reconcile dispatch for '$requestId': $($_.Exception.Message)" -Properties @{ requestId = $requestId; platform = $platform }
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'DispatchFailed'; errorMessage = $_.Exception.Message; completedAt = (Get-Date).ToUniversalTime()
        }
        return [pscustomobject]@{
            Claimed = $true; Reason = ''
            Result  = [pscustomobject]@{ Status = 'DispatchFailed'; ErrorMessage = $_.Exception.Message; Terminal = $true; ReleaseLease = $true }
        }
    }

    $result = Invoke-DisposalDispatch -Message $message -ExpectedPlatform $platform -Attempt $attempt
    return [pscustomobject]@{ Claimed = $true; Reason = ''; Result = $result }
}

# ---------------------------------------------------------------------------
# In-flight reconciliation: polls Automation for requests whose runbook job is
# already known (Dispatched/Running), and for requests waiting on the job's
# output to catch up with its already-terminal status (EvidencePending).
# ---------------------------------------------------------------------------
function Get-InFlightCandidateRequests {
    param([int] $Top = 200)
    return @(Find-WipeRequestState -Filter "status eq 'Dispatched' or status eq 'Running' or status eq 'EvidencePending'" -Top $Top)
}

function Resolve-RequestTerminalStatus {
    <#
    .SYNOPSIS
        Maps a completed Automation job's parsed ##RESULT## onto the request
        state machine. A runbook that completes with per-device errors is
        PartiallyCompleted, not Completed: the process must be able to tell
        "unenrolled but not wiped" from full success.
    #>
    param([string] $JobStatus, $Result)

    if ($JobStatus -ne 'Completed') { return 'Failed' }
    if ($null -eq $Result) { return 'Completed' }

    $hasErrors = $false
    if ($Result.PSObject.Properties.Name -contains 'errors' -and $Result.errors) {
        $hasErrors = @($Result.errors).Count -gt 0
    }

    $wipeIssued = $true
    if ($Result.PSObject.Properties.Name -contains 'wipeIssued') { $wipeIssued = [bool]$Result.wipeIssued }

    if (-not $wipeIssued) { return 'Failed' }
    if ($hasErrors) { return 'PartiallyCompleted' }
    return 'Completed'
}

function Invoke-InFlightReconciliation {
    <#
    .SYNOPSIS
        Reconciles one request whose Automation job is already known: polls
        the job status, and once terminal, requires a valid '##RESULT##' line
        before declaring success. A terminal job with no usable evidence yet
        is retried a bounded number of times as 'EvidencePending'; running out
        of those retries - or the overall per-platform timeout - fails the
        request with evidenceState='EvidenceMissing'.
    .OUTPUTS
        PSCustomObject: Status, EvidenceState, ReleaseLease (bool),
        CallbackEventId (string or $null), Handled (bool - $false when the
        request is still legitimately in progress and nothing changed).
    #>
    param([Parameter(Mandatory)] $Request)

    $platform = [string]$Request.PartitionKey
    $requestId = [string]$Request.RowKey
    $callbackUrl = [string](Get-JsonPropertyValue -InputObject $Request -Name 'callbackUrl')
    $existingEventId = [string](Get-JsonPropertyValue -InputObject $Request -Name 'eventId')

    $logProps = @{
        requestId     = $requestId
        platform      = $platform
        correlationId = Get-JsonPropertyValue -InputObject $Request -Name 'correlationId'
        serialNumber  = Get-JsonPropertyValue -InputObject $Request -Name 'serialNumber'
    }

    $jobName = [string](Get-JsonPropertyValue -InputObject $Request -Name 'automationJobName')
    if ([string]::IsNullOrWhiteSpace($jobName)) {
        Write-AtLog -Level 'Warning' -Message 'JobMonitor: no Automation job name recorded, skipping.' -Properties $logProps
        return [pscustomobject]@{ Status = $Request.status; EvidenceState = $null; ReleaseLease = $false; CallbackEventId = $null; Handled = $false }
    }

    $timeoutMinutes = 60
    $timeoutValue = Get-JsonPropertyValue -InputObject $Request -Name 'timeoutMinutes'
    if ($timeoutValue) { $timeoutMinutes = [int]$timeoutValue }

    $dispatchedAt = $null
    $dispatchedAtValue = Get-JsonPropertyValue -InputObject $Request -Name 'dispatchedAt'
    if ($dispatchedAtValue) { try { $dispatchedAt = [datetime]::Parse($dispatchedAtValue).ToUniversalTime() } catch { $dispatchedAt = $null } }
    $expired = $dispatchedAt -and ((Get-Date).ToUniversalTime() -gt $dispatchedAt.AddMinutes($timeoutMinutes))

    try {
        $job = Get-AutomationRunbookJob -JobName $jobName
    }
    catch {
        Write-AtLog -Level 'Error' -Message "JobMonitor: job lookup failed: $($_.Exception.Message)" -Properties $logProps
        return [pscustomobject]@{ Status = $Request.status; EvidenceState = $null; ReleaseLease = $false; CallbackEventId = $null; Handled = $false }
    }

    if (-not $job) {
        if ($expired) {
            Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
                status = 'Failed'; errorMessage = 'Automation job not found and request timed out.'
                evidenceState = 'EvidenceMissing'; completedAt = (Get-Date).ToUniversalTime()
            }
            $eventId = Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl $callbackUrl -ExistingEventId $existingEventId
            return [pscustomobject]@{ Status = 'Failed'; EvidenceState = 'EvidenceMissing'; ReleaseLease = $true; CallbackEventId = $eventId; Handled = $true }
        }
        return [pscustomobject]@{ Status = $Request.status; EvidenceState = $null; ReleaseLease = $false; CallbackEventId = $null; Handled = $false }
    }

    if (-not (Test-AutomationJobTerminal -Status $job.Status)) {
        if ($expired) {
            Write-AtLog -Level 'Warning' -Message "JobMonitor: request timed out after $timeoutMinutes minutes." -Properties $logProps
            Write-AtAudit -Action 'WipeTimeout' -Level 'Warning' -Properties ($logProps + @{ status = 'Failed'; timeoutMinutes = $timeoutMinutes; lastJobStatus = [string]$job.Status })
            Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
                status = 'Failed'; errorMessage = "Runbook job timeout after $timeoutMinutes minutes (last status: $($job.Status))."
                evidenceState = 'EvidenceMissing'; completedAt = (Get-Date).ToUniversalTime()
            }
            $eventId = Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl $callbackUrl -ExistingEventId $existingEventId
            return [pscustomobject]@{ Status = 'Failed'; EvidenceState = 'EvidenceMissing'; ReleaseLease = $true; CallbackEventId = $eventId; Handled = $true }
        }

        $progress = @{ automationJobId = [string]$job.JobId }
        if ($job.Status -eq 'Running') { $progress.status = 'Running' }
        elseif ($Request.status -eq 'Dispatching') { $progress.status = 'Dispatched' }
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties $progress
        return [pscustomobject]@{ Status = $progress.status; EvidenceState = $null; ReleaseLease = $false; CallbackEventId = $null; Handled = $false }
    }

    # --- Terminal Automation job: require valid evidence before declaring success ---
    $output = Get-AutomationRunbookJobOutput -JobName $jobName
    $result = ConvertFrom-RunbookOutput -Output ([string]$output)
    $evidenceState = Get-RunbookOutputEvidenceState -Output ([string]$output) -ParsedResult $result

    if ($evidenceState -ne 'HasResult') {
        $evidenceAttempts = 0
        $evidenceAttemptsValue = Get-JsonPropertyValue -InputObject $Request -Name 'evidenceAttempts'
        if ($evidenceAttemptsValue) { [int]::TryParse([string]$evidenceAttemptsValue, [ref] $evidenceAttempts) | Out-Null }
        $evidenceAttempts++

        if ($evidenceAttempts -ge (Get-EvidenceMaxAttempts) -or $expired) {
            $errorMessage = "Runbook job '$jobName' completed (status $($job.Status)) but produced no usable evidence after $evidenceAttempts attempt(s) (evidenceState=$evidenceState)."
            Write-AtLog -Level 'Error' -Message $errorMessage -Properties $logProps
            Write-AtAudit -Action 'WipeTerminalState' -Level 'Error' -Properties ($logProps + @{ status = 'Failed'; evidenceState = $evidenceState; errorMessage = $errorMessage })
            Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
                status = 'Failed'; errorMessage = $errorMessage; evidenceState = 'EvidenceMissing'
                jobStatus = [string]$job.Status; automationJobId = [string]$job.JobId; evidenceAttempts = $evidenceAttempts
                completedAt = (Get-Date).ToUniversalTime()
            }
            $eventId = Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl $callbackUrl -ExistingEventId $existingEventId
            return [pscustomobject]@{ Status = 'Failed'; EvidenceState = 'EvidenceMissing'; ReleaseLease = $true; CallbackEventId = $eventId; Handled = $true }
        }

        Write-AtLog -Level 'Warning' -Message "JobMonitor: job '$jobName' terminal but evidence not yet usable ($evidenceState), attempt $evidenceAttempts/$(Get-EvidenceMaxAttempts)." -Properties $logProps
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'EvidencePending'; jobStatus = [string]$job.Status; automationJobId = [string]$job.JobId
            evidenceState = $evidenceState; evidenceAttempts = $evidenceAttempts
        }
        return [pscustomobject]@{ Status = 'EvidencePending'; EvidenceState = $evidenceState; ReleaseLease = $false; CallbackEventId = $null; Handled = $false }
    }

    $status = Resolve-RequestTerminalStatus -JobStatus $job.Status -Result $result
    $errorMessage = ''
    if ($status -ne 'Completed') {
        $errorMessage = if ($job.Exception) { "$($job.Exception)" } elseif ($job.StatusDetails) { "$($job.StatusDetails)" } else { "Runbook job status: $($job.Status)" }
    }

    $updates = @{
        status          = $status
        completedAt     = (Get-Date).ToUniversalTime()
        jobStatus       = [string]$job.Status
        automationJobId = [string]$job.JobId
        errorMessage    = $errorMessage
        evidenceState   = 'HasResult'
        resultJson      = $result
    }
    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties $updates

    $logProps.status = $status
    Write-AtLog -Level 'Information' -Message 'JobMonitor: request reached a terminal state.' -Properties $logProps
    $auditLevel = if ($status -eq 'Completed') { 'Information' } elseif ($status -eq 'PartiallyCompleted') { 'Warning' } else { 'Error' }
    Write-AtAudit -Action 'WipeTerminalState' -Level $auditLevel -Properties ($logProps + @{ jobStatus = [string]$job.Status; errorMessage = $errorMessage })

    $eventId = Set-CallbackPending -Platform $platform -RequestId $requestId -CallbackUrl $callbackUrl -ExistingEventId $existingEventId
    return [pscustomobject]@{ Status = $status; EvidenceState = 'HasResult'; ReleaseLease = $true; CallbackEventId = $eventId; Handled = $true }
}

# ---------------------------------------------------------------------------
# Durable callback reconciliation
# ---------------------------------------------------------------------------
function Get-CallbackCandidateRequests {
    param([int] $Top = 200)
    return @(Find-WipeRequestState -Filter "callbackStatus eq 'Pending' or callbackStatus eq 'FailedRetryable'" -Top $Top)
}

function Test-CallbackAttemptDue {
    param($Request)
    return Test-BackoffFieldDue -Request $Request -FieldName 'callbackNextAttemptAt'
}

function Get-DueCallbackCandidates {
    param([int] $MaxConcurrency = -1)

    if ($MaxConcurrency -lt 0) { $MaxConcurrency = Get-CallbackMaxConcurrency }
    $candidates = @(Get-CallbackCandidateRequests | Where-Object { Test-CallbackAttemptDue -Request $_ })
    return @($candidates | Select-Object -First $MaxConcurrency)
}

function ConvertTo-CallbackPayload {
    <#
    .SYNOPSIS
        Builds the ServiceNow callback body from a durable state row. requestId
        and eventId are included in the body (not just the headers) so the
        receiver can de-duplicate even if it only inspects the payload.
    #>
    param($Request, [Parameter(Mandatory)] [string] $EventId)

    $result = $null
    $resultJson = Get-JsonPropertyValue -InputObject $Request -Name 'resultJson'
    if ($resultJson) {
        try { $result = [string]$resultJson | ConvertFrom-Json } catch { $result = [string]$resultJson }
    }

    return [ordered]@{
        requestId         = $Request.RowKey
        eventId           = $EventId
        correlationId     = Get-JsonPropertyValue -InputObject $Request -Name 'correlationId'
        platform          = $Request.PartitionKey
        scenario          = Get-JsonPropertyValue -InputObject $Request -Name 'scenario'
        status            = Get-JsonPropertyValue -InputObject $Request -Name 'status'
        dryRun            = Get-JsonPropertyValue -InputObject $Request -Name 'dryRun'
        device            = [ordered]@{
            serialNumber    = Get-JsonPropertyValue -InputObject $Request -Name 'serialNumber'
            imei            = Get-JsonPropertyValue -InputObject $Request -Name 'imei'
            deviceName      = Get-JsonPropertyValue -InputObject $Request -Name 'deviceName'
            managedDeviceId = Get-JsonPropertyValue -InputObject $Request -Name 'managedDeviceId'
        }
        automationJobName = Get-JsonPropertyValue -InputObject $Request -Name 'automationJobName'
        automationJobId   = Get-JsonPropertyValue -InputObject $Request -Name 'automationJobId'
        dispatchedAt      = Get-JsonPropertyValue -InputObject $Request -Name 'dispatchedAt'
        completedAt       = Get-JsonPropertyValue -InputObject $Request -Name 'completedAt'
        errorMessage      = Get-JsonPropertyValue -InputObject $Request -Name 'errorMessage'
        evidenceState     = Get-JsonPropertyValue -InputObject $Request -Name 'evidenceState'
        result            = $result
    }
}

function Send-WipeRequestCallback {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] $Payload,
        [Parameter(Mandatory)] [string] $EventId
    )

    $headers = @{
        'X-Request-Id'   = [string]$Payload.requestId
        'X-Event-Id'     = $EventId
        'Idempotency-Key' = $EventId
    }
    Invoke-RestMethod -Uri $Url -Method POST -Headers $headers -ContentType 'application/json' `
        -Body ($Payload | ConvertTo-Json -Depth 12) -TimeoutSec 30 | Out-Null
}

function Invoke-CallbackReconciliation {
    <#
    .SYNOPSIS
        Delivers (or retries) one durable callback. Claims the row with an
        ETag-conditional MERGE first so two JobMonitor passes can never send
        the same callback twice; reaches a final Sent/Failed state once
        delivered or once CALLBACK_MAX_ATTEMPTS is exhausted, otherwise
        schedules the next attempt with backoff (FailedRetryable).
    #>
    param([Parameter(Mandatory)] $Request)

    $platform = [string]$Request.PartitionKey
    $requestId = [string]$Request.RowKey

    $current = Get-WipeRequestStateWithETag -Platform $platform -RequestId $requestId
    if (-not $current) { return [pscustomobject]@{ Claimed = $false; Reason = 'NotFound'; Outcome = $null } }
    if ([string]$current.Entity.callbackStatus -notin @('Pending', 'FailedRetryable')) {
        return [pscustomobject]@{ Claimed = $false; Reason = 'NotEligible'; Outcome = $null }
    }

    $priorAttempts = 0
    $priorAttemptsValue = Get-JsonPropertyValue -InputObject $current.Entity -Name 'callbackAttempts'
    if ($priorAttemptsValue) { [int]::TryParse([string]$priorAttemptsValue, [ref] $priorAttempts) | Out-Null }
    $attempt = $priorAttempts + 1

    $claimed = Set-WipeRequestStateClaim -Platform $platform -RequestId $requestId -ETag $current.ETag -Properties @{
        callbackAttempts   = $attempt
        callbackClaimedAt  = (Get-Date).ToUniversalTime()
    }
    if (-not $claimed) { return [pscustomobject]@{ Claimed = $false; Reason = 'ClaimConflict'; Outcome = $null } }

    $callbackUrl = [string](Get-JsonPropertyValue -InputObject $current.Entity -Name 'callbackUrl')
    if ([string]::IsNullOrWhiteSpace($callbackUrl)) {
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{ callbackStatus = 'Failed'; callbackError = 'callbackUrl missing' }
        return [pscustomobject]@{ Claimed = $true; Reason = ''; Outcome = 'Failed' }
    }

    $eventId = [string](Get-JsonPropertyValue -InputObject $current.Entity -Name 'eventId')
    if ([string]::IsNullOrWhiteSpace($eventId)) { $eventId = [guid]::NewGuid().ToString() }

    $payload = ConvertTo-CallbackPayload -Request $current.Entity -EventId $eventId
    $logProps = @{ requestId = $requestId; platform = $platform; attempt = $attempt; eventId = $eventId }

    try {
        Send-WipeRequestCallback -Url $callbackUrl -Payload $payload -EventId $eventId
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            callbackStatus = 'Sent'; callbackSentAt = (Get-Date).ToUniversalTime(); callbackError = ''; eventId = $eventId
        }
        Write-AtAudit -Action 'WipeCallbackSent' -Properties $logProps
        return [pscustomobject]@{ Claimed = $true; Reason = ''; Outcome = 'Sent' }
    }
    catch {
        $maxAttempts = Get-CallbackMaxAttempts
        if ($attempt -ge $maxAttempts) {
            Write-AtLog -Level 'Error' -Message "JobMonitor: callback delivery failed permanently after $attempt attempts: $($_.Exception.Message)" -Properties $logProps
            Write-AtAudit -Action 'WipeCallbackFailed' -Level 'Error' -Properties ($logProps + @{ error = $_.Exception.Message })
            Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
                callbackStatus = 'Failed'; callbackError = $_.Exception.Message; eventId = $eventId
            }
            return [pscustomobject]@{ Claimed = $true; Reason = ''; Outcome = 'Failed' }
        }

        $delay = Get-BackoffDelaySeconds -Attempt $attempt -BaseSeconds (Get-CallbackBackoffBaseSeconds) -MaxSeconds (Get-CallbackBackoffMaxSeconds)
        $nextAttemptAt = (Get-Date).ToUniversalTime().AddSeconds($delay)
        Write-AtLog -Level 'Warning' -Message "JobMonitor: callback delivery failed (attempt $attempt/$maxAttempts), retrying at $($nextAttemptAt.ToString('o')): $($_.Exception.Message)" -Properties $logProps
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            callbackStatus = 'FailedRetryable'; callbackError = $_.Exception.Message
            callbackNextAttemptAt = $nextAttemptAt; eventId = $eventId
        }
        return [pscustomobject]@{ Claimed = $true; Reason = ''; Outcome = 'FailedRetryable' }
    }
}

Export-ModuleMember -Function Invoke-DisposalDispatch, Invoke-DispatchReconciliation, Invoke-DispatchClaim, `
    Get-DispatchCandidateRequests, Test-DispatchAttemptDue, Get-DueDispatchCandidates, `
    ConvertTo-DispatchMessage, Get-DispatchMaxAttempts, Get-DispatchBackoffBaseSeconds, `
    Get-DispatchBackoffMaxSeconds, Get-DispatchMaxConcurrency, Test-BackoffFieldDue, `
    Set-CallbackPending, Get-EvidenceMaxAttempts, `
    Get-InFlightCandidateRequests, Resolve-RequestTerminalStatus, Invoke-InFlightReconciliation, `
    Get-CallbackCandidateRequests, Test-CallbackAttemptDue, Get-DueCallbackCandidates, `
    ConvertTo-CallbackPayload, Send-WipeRequestCallback, Invoke-CallbackReconciliation, `
    Get-CallbackMaxAttempts, Get-CallbackBackoffBaseSeconds, Get-CallbackBackoffMaxSeconds, Get-CallbackMaxConcurrency
