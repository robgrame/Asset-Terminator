param($Context)

# Durable orchestration for a single decommission request. Parity with
# DecommissionOrchestrator.cs. Kept thin/deterministic: all real work lives in
# activities. Fan-out/fan-in uses Invoke-DurableActivity -NoWait + Wait-DurableTask;
# waiting between pre-wipe polls uses durable timers (Start-DurableTimer).
#
# Terminate: enrich/validate -> object deletes incl. Autopilot (always before wipe)
#   -> on-device pre-wipe preventive actions dispatched and awaited to completion
#   -> guardrail-gated wipe -> finalize.
# Retire:    enrich/validate -> object deletes + Intune retire -> finalize.

$ErrorActionPreference = 'Stop'

$requestId = $Context.Input

$meta = Invoke-DurableActivity -FunctionName 'EnrichAndValidate' -Input $requestId
$targets = @($meta.Targets)

# --- Retire (re-purpose): no wipe, no Autopilot removal, no preventive actions. ---
if ($meta.Disposition -eq 'Retire') {
    $tasks = @()
    foreach ($t in $targets) {
        if (Test-IsObjectDeleteTarget -Target $t) {
            $tasks += Invoke-DurableActivity -FunctionName 'ExecuteDelete' -Input @{ RequestId = $requestId; Target = $t } -NoWait
        }
    }
    if ($targets -contains 'Retire') {
        $tasks += Invoke-DurableActivity -FunctionName 'ExecuteRetire' -Input $requestId -NoWait
    }
    if ($tasks.Count -gt 0) { Wait-DurableTask -Task $tasks | Out-Null }
    Invoke-DurableActivity -FunctionName 'Finalize' -Input $requestId | Out-Null
    return
}

# --- Terminate ---

# 1. Object deletes (AD, ConfigMgr, Intune, EntraId) + Autopilot removal, in parallel.
#    Awaiting these guarantees the Autopilot registration is removed before the wipe.
$deleteTargets = @($targets | Where-Object { Test-IsObjectDeleteOrAutopilotTarget -Target $_ })
if ($deleteTargets.Count -gt 0) {
    $tasks = @()
    foreach ($t in $deleteTargets) {
        $tasks += Invoke-DurableActivity -FunctionName 'ExecuteDelete' -Input @{ RequestId = $requestId; Target = $t } -NoWait
    }
    Wait-DurableTask -Task $tasks | Out-Null
}

$wipeRequested = $targets -contains 'Wipe'

# 2. On-device pre-wipe preventive actions (license step-down + BIOS password removal).
$preWipeTargets = @($targets | Where-Object { Test-IsPreWipeGatingTarget -Target $_ })
if ($preWipeTargets.Count -gt 0) {
    $tasks = @()
    foreach ($t in $preWipeTargets) {
        $tasks += Invoke-DurableActivity -FunctionName 'ExecuteDelete' -Input @{ RequestId = $requestId; Target = $t } -NoWait
    }
    Wait-DurableTask -Task $tasks | Out-Null

    if ($wipeRequested) {
        $interval = [int]$meta.PreWipePollIntervalSeconds
        if ($interval -le 0) { $interval = 300 }

        while ($true) {
            $status = Invoke-DurableActivity -FunctionName 'CheckPreWipeActions' `
                -Input @{ RequestId = $requestId; Targets = $preWipeTargets }
            if ($status.AllTerminal -or $status.DeadlinePassed) { break }
            Start-DurableTimer -Duration (New-TimeSpan -Seconds $interval) | Out-Null
        }

        if (-not $status.AllSucceeded -and $meta.RequirePreWipeCompletion) {
            $reasons = @($status.FailedReasons)
            if ($reasons.Count -eq 0) { $reasons = @('pre-wipe preventive actions did not complete before the deadline') }
            Invoke-DurableActivity -FunctionName 'BlockWipe' `
                -Input @{ RequestId = $requestId; Reasons = $reasons; CallbackEvent = 'PreWipeBlocked' } | Out-Null
            return
        }
    }
}

# 3. Guardrail-gated wipe.
if ($wipeRequested) {
    $outcome = Invoke-DurableActivity -FunctionName 'EvaluateGuardrails' -Input $requestId
    if ($outcome.Allowed) {
        Invoke-DurableActivity -FunctionName 'IssueWipe' -Input $requestId | Out-Null
    }
    else {
        Invoke-DurableActivity -FunctionName 'BlockWipe' `
            -Input @{ RequestId = $requestId; Reasons = @($outcome.BlockingReasons) } | Out-Null
        return
    }
}

# 4. Finalize.
Invoke-DurableActivity -FunctionName 'Finalize' -Input $requestId | Out-Null
