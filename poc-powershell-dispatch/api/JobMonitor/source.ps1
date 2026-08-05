#Requires -Version 7.6

# JobMonitor handler - durable reconciliation, run on a timer.
#
# The runbooks take minutes (Windows) to tens of minutes (Apple, which waits for
# the DEP sync to propagate), so nothing in the pipeline blocks on them, and the
# HTTP intake's own dispatch attempt is only best-effort. This timer is what
# actually guarantees forward progress, in three independent passes:
#
#   1. Dispatch reconciliation - claims (ETag-conditional) every request still
#      Accepted or Dispatching whose backoff window has elapsed, and attempts
#      to start (or confirm) its Automation job. Handles crash recovery (a
#      request that was Accepted but never attempted), retries with backoff up
#      to a bounded number of attempts, and the ARM PUT ambiguity (timeout /
#      429 / 5xx) without ever double-starting a job or releasing the device
#      lease on an inconclusive outcome.
#   2. In-flight reconciliation - polls the Automation job status for requests
#      already Dispatched/Running/EvidencePending, and only declares success
#      once a valid '##RESULT##' line has been read back; a terminal job with
#      no usable output yet is retried a bounded number of times before being
#      failed with evidenceState=EvidenceMissing.
#   3. Callback reconciliation - delivers (or retries with backoff) the
#      ServiceNow callback for every request whose callbackStatus is Pending or
#      FailedRetryable, including dry-run completions, using a stable eventId
#      so retried deliveries are idempotent for the receiver.
#
# Every one of these passes claims its row before acting, so a slow HTTP
# request and a JobMonitor tick - or two overlapping ticks - can never step on
# each other.

param($Timer)

$dispatchCandidates = @(Get-DueDispatchCandidates)
Write-AtLog -Level 'Information' -Message "JobMonitor: $($dispatchCandidates.Count) request(s) due for a dispatch attempt."
foreach ($candidate in $dispatchCandidates) {
    $requestId = [string]$candidate.RowKey
    try {
        $reconciliation = Invoke-DispatchReconciliation -Request $candidate
        if (-not $reconciliation.Claimed) {
            Write-AtLog -Level 'Information' -Message "JobMonitor: dispatch claim skipped for '$requestId' ($($reconciliation.Reason))."
            continue
        }

        if ($reconciliation.Result.ReleaseLease) {
            try {
                Unlock-WipeDevice -SerialNumber ([string]$candidate.serialNumber) -RequestId $requestId | Out-Null
            }
            catch {
                Write-AtLog -Level 'Error' -Message "JobMonitor: failed to release the device lease for '$requestId': $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-AtLog -Level 'Error' -Message "JobMonitor: dispatch reconciliation failed for '$requestId': $($_.Exception.Message)"
    }
}

$inFlightCandidates = @(Get-InFlightCandidateRequests)
Write-AtLog -Level 'Information' -Message "JobMonitor: $($inFlightCandidates.Count) request(s) in flight."
foreach ($candidate in $inFlightCandidates) {
    $requestId = [string]$candidate.RowKey
    try {
        $reconciliation = Invoke-InFlightReconciliation -Request $candidate
        if ($reconciliation.ReleaseLease) {
            try {
                Unlock-WipeDevice -SerialNumber ([string]$candidate.serialNumber) -RequestId $requestId | Out-Null
            }
            catch {
                Write-AtLog -Level 'Error' -Message "JobMonitor: failed to release the device lease for '$requestId': $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-AtLog -Level 'Error' -Message "JobMonitor: in-flight reconciliation failed for '$requestId': $($_.Exception.Message)"
    }
}

$callbackCandidates = @(Get-DueCallbackCandidates)
Write-AtLog -Level 'Information' -Message "JobMonitor: $($callbackCandidates.Count) callback(s) due."
foreach ($candidate in $callbackCandidates) {
    $requestId = [string]$candidate.RowKey
    try {
        $reconciliation = Invoke-CallbackReconciliation -Request $candidate
        if (-not $reconciliation.Claimed) {
            Write-AtLog -Level 'Information' -Message "JobMonitor: callback claim skipped for '$requestId' ($($reconciliation.Reason))."
        }
    }
    catch {
        Write-AtLog -Level 'Error' -Message "JobMonitor: callback reconciliation failed for '$requestId': $($_.Exception.Message)"
    }
}

