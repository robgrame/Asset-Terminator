# JobMonitor - asynchronous completion.
#
# The runbooks take minutes (Windows) to tens of minutes (Apple, which waits for
# the DEP sync to propagate), so nothing in the pipeline blocks on them. This
# timer reconciles the outcome over time:
#
#   1. read the requests still in flight;
#   2. poll the Automation job status;
#   3. on a terminal status, fetch the job output and extract the structured
#      '##RESULT## {json}' line;
#   4. persist the outcome and the technical evidence;
#   5. send the ServiceNow callback (with retry, then a dead-letter queue).
#
# Requests older than the platform timeout are failed explicitly so they never
# stay in flight forever.

param($Timer)

Import-Module "$PSScriptRoot/../Modules/AT.Common.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/AT.State.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/AT.Automation.psm1" -Force

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
            return $true
        }
        catch {
            if ($attempt -eq $MaxAttempts) { throw }
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
        }
    }
    return $false
}

# Maps the Automation job status onto the request state machine. A runbook that
# completes with per-device errors is PartiallyCompleted, not Completed: the
# process must be able to tell "unenrolled but not wiped" from full success.
function Resolve-RequestStatus {
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

$inFlight = @('Dispatched', 'Running')
$filter = ($inFlight | ForEach-Object { "status eq '$_'" }) -join ' or '

try {
    $requests = Find-WipeRequestState -Filter $filter -Top 200
}
catch {
    Write-AtLog -Level 'Error' -Message "JobMonitor: state store query failed: $($_.Exception.Message)"
    return
}

Write-AtLog -Level 'Information' -Message "JobMonitor: $($requests.Count) request(s) in flight."

foreach ($request in $requests) {
    $platform = $request.PartitionKey
    $requestId = $request.RowKey

    $logProps = @{
        requestId     = $requestId
        platform      = $platform
        correlationId = $request.correlationId
        serialNumber  = $request.serialNumber
    }

    $jobName = if ($request.PSObject.Properties.Name -contains 'automationJobName') { [string]$request.automationJobName } else { $null }
    if ([string]::IsNullOrWhiteSpace($jobName)) {
        Write-AtLog -Level 'Warning' -Message 'JobMonitor: no Automation job name recorded, skipping.' -Properties $logProps
        continue
    }

    # --- Timeout guard ------------------------------------------------------
    $timeoutMinutes = 60
    if ($request.PSObject.Properties.Name -contains 'timeoutMinutes' -and $request.timeoutMinutes) {
        $timeoutMinutes = [int]$request.timeoutMinutes
    }

    $dispatchedAt = $null
    if ($request.PSObject.Properties.Name -contains 'dispatchedAt' -and $request.dispatchedAt) {
        try { $dispatchedAt = [datetime]::Parse($request.dispatchedAt).ToUniversalTime() } catch { $dispatchedAt = $null }
    }

    $expired = $dispatchedAt -and ((Get-Date).ToUniversalTime() -gt $dispatchedAt.AddMinutes($timeoutMinutes))

    # --- Poll ---------------------------------------------------------------
    try {
        $job = Get-AutomationRunbookJob -JobName $jobName
    }
    catch {
        Write-AtLog -Level 'Error' -Message "JobMonitor: job lookup failed: $($_.Exception.Message)" -Properties $logProps
        continue
    }

    if (-not $job) {
        if ($expired) {
            Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
                status = 'Failed'; errorMessage = 'Automation job not found and request timed out.'
                completedAt = (Get-Date).ToUniversalTime()
            }
        }
        continue
    }

    if (-not (Test-AutomationJobTerminal -Status $job.Status)) {
        if ($expired) {
            Write-AtLog -Level 'Warning' -Message "JobMonitor: request timed out after $timeoutMinutes minutes." -Properties $logProps
            Write-AtAudit -Action 'WipeTimeout' -Level 'Warning' -Properties ($logProps + @{ status = 'Failed'; timeoutMinutes = $timeoutMinutes; lastJobStatus = [string]$job.Status })
            Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
                status = 'Failed'; errorMessage = "Runbook job timeout after $timeoutMinutes minutes (last status: $($job.Status))."
                completedAt = (Get-Date).ToUniversalTime()
            }
        }
        elseif ($request.status -ne 'Running' -and $job.Status -eq 'Running') {
            Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{ status = 'Running' }
        }
        continue
    }

    # --- Terminal: collect the evidence -------------------------------------
    $output = Get-AutomationRunbookJobOutput -JobName $jobName
    $result = ConvertFrom-RunbookOutput -Output ([string]$output)
    $status = Resolve-RequestStatus -JobStatus $job.Status -Result $result

    $errorMessage = ''
    if ($status -ne 'Completed') {
        $errorMessage = if ($job.Exception) { "$($job.Exception)" } elseif ($job.StatusDetails) { "$($job.StatusDetails)" } else { "Runbook job status: $($job.Status)" }
    }

    $updates = @{
        status       = $status
        completedAt  = (Get-Date).ToUniversalTime()
        jobStatus    = [string]$job.Status
        errorMessage = $errorMessage
    }
    if ($result) { $updates['resultJson'] = $result }
    # Keep the raw stream as evidence when the runbook has no ##RESULT## line yet.
    elseif ($output) { $updates['rawOutput'] = ([string]$output).Substring(0, [Math]::Min(30000, ([string]$output).Length)) }

    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties $updates

    $logProps.status = $status
    Write-AtLog -Level 'Information' -Message 'JobMonitor: request reached a terminal state.' -Properties $logProps
    $auditLevel = if ($status -eq 'Completed') { 'Information' } elseif ($status -eq 'PartiallyCompleted') { 'Warning' } else { 'Error' }
    Write-AtAudit -Action 'WipeTerminalState' -Level $auditLevel -Properties ($logProps + @{ jobStatus = [string]$job.Status; errorMessage = $errorMessage })

    # --- Callback -----------------------------------------------------------
    $callbackUrl = if ($request.PSObject.Properties.Name -contains 'callbackUrl') { [string]$request.callbackUrl } else { '' }
    if ([string]::IsNullOrWhiteSpace($callbackUrl)) { continue }

    $callback = [ordered]@{
        requestId         = $requestId
        correlationId     = $request.correlationId
        platform          = $platform
        scenario          = $request.scenario
        status            = $status
        device            = [ordered]@{
            serialNumber    = $request.serialNumber
            imei            = $request.imei
            deviceName      = $request.deviceName
            managedDeviceId = $request.managedDeviceId
        }
        automationJobName = $jobName
        automationJobId   = $request.automationJobId
        dispatchedAt      = $request.dispatchedAt
        completedAt       = $updates.completedAt.ToString('o')
        errorMessage      = $errorMessage
        result            = $result
    }

    try {
        Send-ServiceNowCallback -Url $callbackUrl -Payload $callback | Out-Null
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{ callbackStatus = 'Sent' }
        Write-AtAudit -Action 'WipeCallbackSent' -Properties ($logProps + @{ status = $status })
    }
    catch {
        Write-AtLog -Level 'Error' -Message "JobMonitor: callback failed: $($_.Exception.Message)" -Properties $logProps
        Write-AtAudit -Action 'WipeCallbackFailed' -Level 'Error' -Properties ($logProps + @{ status = $status; error = $_.Exception.Message })
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            callbackStatus = 'Failed'; callbackError = $_.Exception.Message
        }
    }
}
