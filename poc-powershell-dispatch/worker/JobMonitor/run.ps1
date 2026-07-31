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
Import-Module "$PSScriptRoot/../Modules/AT.Graph.psm1" -Force
Import-Module "$PSScriptRoot/../Modules/AT.Callback.psm1" -Force

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

    if ($Result.PSObject.Properties.Name -contains 'dryRun' -and [bool]$Result.dryRun) {
        return $(if ($hasErrors) { 'PartiallyCompleted' } else { 'Completed' })
    }

    $wipeIssued = $true
    if ($Result.PSObject.Properties.Name -contains 'wipeIssued') { $wipeIssued = [bool]$Result.wipeIssued }

    if (-not $wipeIssued) { return 'Failed' }
    return 'PendingDeviceAction'
}

function Get-EntityProperty {
    param($Entity, [string] $Name, $Default = $null)

    if ($Entity.PSObject.Properties.Name -contains $Name -and $null -ne $Entity.$Name) {
        return $Entity.$Name
    }
    return $Default
}

function Merge-LogProperties {
    param(
        [Parameter(Mandatory)] [hashtable] $Properties,
        [Parameter(Mandatory)] [hashtable] $AdditionalProperties
    )

    $merged = @{} + $Properties
    foreach ($key in $AdditionalProperties.Keys) {
        $merged[$key] = $AdditionalProperties[$key]
    }
    return $merged
}

function Complete-RunbookRequest {
    param(
        [Parameter(Mandatory)] $Request,
        [Parameter(Mandatory)] [string] $Status,
        [string] $ErrorMessage = '',
        $Result,
        [string] $JobStatus = '',
        [Parameter(Mandatory)] [hashtable] $LogProperties
    )

    $completedAt = (Get-Date).ToUniversalTime()
    $updates = @{
        status       = $Status
        completedAt  = $completedAt
        errorMessage = $ErrorMessage
    }
    if (-not [string]::IsNullOrWhiteSpace($JobStatus)) {
        $updates['jobStatus'] = $JobStatus
    }
    Update-WipeRequestState -Platform $Request.PartitionKey -RequestId $Request.RowKey -Properties $updates

    $level = if ($Status -eq 'Completed') { 'Information' } elseif ($Status -eq 'PartiallyCompleted') { 'Warning' } else { 'Error' }
    Write-AtAudit -Action 'WipeTerminalState' -Level $level -Properties (Merge-LogProperties -Properties $LogProperties -AdditionalProperties @{
        status = $Status
        jobStatus = $JobStatus
        errorMessage = $ErrorMessage
    })
    Send-RequestCallback -Request $Request -Status $Status -CompletedAt $completedAt -ErrorMessage $ErrorMessage -Result $Result -LogProperties $LogProperties
}

function Complete-DeviceActionRequest {
    param(
        [Parameter(Mandatory)] $Request,
        [Parameter(Mandatory)] [string] $Status,
        [Parameter(Mandatory)] [string] $DeviceActionState,
        [string] $ErrorMessage = '',
        $Result,
        [Parameter(Mandatory)] [hashtable] $LogProperties
    )

    $completedAt = (Get-Date).ToUniversalTime()
    Update-WipeRequestState -Platform $Request.PartitionKey -RequestId $Request.RowKey -Properties @{
        status                    = $Status
        completedAt               = $completedAt
        deviceActionState         = $DeviceActionState
        deviceActionLastCheckedAt = $completedAt
        errorMessage              = $ErrorMessage
    }

    $level = if ($Status -eq 'Completed') { 'Information' } elseif ($Status -eq 'PartiallyCompleted') { 'Warning' } else { 'Error' }
    Write-AtAudit -Action 'WipeTerminalState' -Level $level -Properties (Merge-LogProperties -Properties $LogProperties -AdditionalProperties @{
        status = $Status
        deviceActionState = $DeviceActionState
        errorMessage = $ErrorMessage
    })
    Send-RequestCallback -Request $Request -Status $Status -CompletedAt $completedAt -ErrorMessage $ErrorMessage -Result $Result -LogProperties $LogProperties
}

function Invoke-DeviceActionReconciliation {
    param(
        [Parameter(Mandatory)] $Request,
        [Parameter(Mandatory)] [hashtable] $LogProperties
    )

    $managedDeviceId = [string](Get-EntityProperty -Entity $Request -Name 'managedDeviceId' -Default '')
    $pollCount = [int](Get-EntityProperty -Entity $Request -Name 'deviceActionPollCount' -Default 0) + 1
    $checkedAt = (Get-Date).ToUniversalTime()
    $timeoutMinutes = Get-AppSettingInt -Name 'DEVICE_ACTION_TIMEOUT_MINUTES' -Default 10080
    $wipeIssuedAt = $null
    try {
        $wipeIssuedAt = [datetime]::Parse([string](Get-EntityProperty -Entity $Request -Name 'wipeIssuedAt' -Default $Request.dispatchedAt)).ToUniversalTime()
    }
    catch {
        $wipeIssuedAt = $checkedAt
    }
    $expired = $checkedAt -gt $wipeIssuedAt.AddMinutes($timeoutMinutes)

    if ([string]::IsNullOrWhiteSpace($managedDeviceId)) {
        $error = 'Cannot reconcile the Intune wipe because managedDeviceId is missing.'
        Complete-DeviceActionRequest -Request $Request -Status 'Failed' -DeviceActionState 'unknown' -ErrorMessage $error -LogProperties $LogProperties
        return
    }

    try {
        $action = Get-DeviceWipeStatus -ManagedDeviceId $managedDeviceId -IssuedAt $wipeIssuedAt -LogProperties $LogProperties
    }
    catch {
        $error = $_.Exception.Message
        Update-WipeRequestState -Platform $Request.PartitionKey -RequestId $Request.RowKey -Properties @{
            deviceActionPollCount     = $pollCount
            deviceActionLastCheckedAt = $checkedAt
            deviceActionLastError     = $error
        }
        Write-AtAudit -Action 'WipeDeviceActionCheckFailed' -Level 'Warning' -Properties ($LogProperties + @{
            pollCount = $pollCount
            error = $error
            expired = $expired
        })
        if ($expired) {
            Complete-DeviceActionRequest -Request $Request -Status 'Failed' -DeviceActionState 'timeout' `
                -ErrorMessage "Intune wipe status could not be verified within $timeoutMinutes minutes: $error" -LogProperties $LogProperties
        }
        return
    }

    $deviceActionState = if ($action.Found) { [string]$action.WipeState } else { 'deviceRemoved' }
    $updates = @{
        deviceActionState             = $deviceActionState
        deviceActionPollCount         = $pollCount
        deviceActionLastCheckedAt     = $checkedAt
        deviceActionLastError         = ''
        errorMessage                  = ''
        deviceActionManagementState   = if ($action.Found) { [string]$action.ManagementState } else { 'notFound' }
        deviceActionLastSyncDateTime  = if ($action.Found -and $action.LastSyncDateTime) { [string]$action.LastSyncDateTime } else { '' }
        deviceActionLastUpdatedAt     = if ($action.Found -and $action.WipeLastUpdatedDateTime) { [string]$action.WipeLastUpdatedDateTime } else { '' }
    }
    Update-WipeRequestState -Platform $Request.PartitionKey -RequestId $Request.RowKey -Properties $updates
    Write-AtAudit -Action 'WipeDeviceActionChecked' -Properties ($LogProperties + @{
        pollCount = $pollCount
        deviceActionState = $deviceActionState
        managementState = $updates.deviceActionManagementState
        expired = $expired
    })

    $result = $null
    if ($Request.resultJson) {
        try { $result = $Request.resultJson | ConvertFrom-Json } catch { $result = $Request.resultJson }
    }
    $successStatus = [string](Get-EntityProperty -Entity $Request -Name 'deviceActionSuccessStatus' -Default 'Completed')

    if (-not $action.Found -or $deviceActionState -eq 'done') {
        Complete-DeviceActionRequest -Request $Request -Status $successStatus -DeviceActionState $deviceActionState -Result $result -LogProperties $LogProperties
        return
    }

    if ($deviceActionState -in @('failed', 'canceled', 'notSupported')) {
        $error = "Intune wipe reached terminal state '$deviceActionState'."
        Complete-DeviceActionRequest -Request $Request -Status 'Failed' -DeviceActionState $deviceActionState -ErrorMessage $error -Result $result -LogProperties $LogProperties
        return
    }

    if ($expired) {
        $error = "Intune wipe remained '$deviceActionState' for more than $timeoutMinutes minutes."
        Complete-DeviceActionRequest -Request $Request -Status 'Failed' -DeviceActionState 'timeout' -ErrorMessage $error -Result $result -LogProperties $LogProperties
    }
}

$inFlight = @('Dispatched', 'Running', 'PendingDeviceAction')
$filter = ($inFlight | ForEach-Object { "status eq '$_'" }) -join ' or '

try {
    $requests = Find-WipeRequestState -Filter $filter -Top 200 -All
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

    if ($request.status -eq 'PendingDeviceAction') {
        Invoke-DeviceActionReconciliation -Request $request -LogProperties $logProps
        continue
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
            $error = 'Automation job not found and request timed out.'
            Write-AtAudit -Action 'WipeTimeout' -Level 'Warning' -Properties (Merge-LogProperties -Properties $logProps -AdditionalProperties @{
                status = 'Failed'
                timeoutMinutes = $timeoutMinutes
                lastJobStatus = 'NotFound'
            })
            Complete-RunbookRequest -Request $request -Status 'Failed' -ErrorMessage $error -JobStatus 'NotFound' -LogProperties $logProps
        }
        continue
    }

    if (-not (Test-AutomationJobTerminal -Status $job.Status)) {
        if ($expired) {
            Write-AtLog -Level 'Warning' -Message "JobMonitor: request timed out after $timeoutMinutes minutes." -Properties $logProps
            Write-AtAudit -Action 'WipeTimeout' -Level 'Warning' -Properties (Merge-LogProperties -Properties $logProps -AdditionalProperties @{
                status = 'Failed'
                timeoutMinutes = $timeoutMinutes
                lastJobStatus = [string]$job.Status
            })
            $error = "Runbook job timeout after $timeoutMinutes minutes (last status: $($job.Status))."
            Complete-RunbookRequest -Request $request -Status 'Failed' -ErrorMessage $error -JobStatus ([string]$job.Status) -LogProperties $logProps
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
    if ($status -in @('Failed', 'PartiallyCompleted')) {
        $errorMessage = if ($job.Exception) { "$($job.Exception)" } elseif ($job.StatusDetails) { "$($job.StatusDetails)" } else { "Runbook job status: $($job.Status)" }
    }

    $completedAt = (Get-Date).ToUniversalTime()
    $updates = @{
        status       = $status
        jobStatus    = [string]$job.Status
        errorMessage = $errorMessage
    }
    if ($status -eq 'PendingDeviceAction') {
        $hasErrors = $false
        if ($result -and $result.PSObject.Properties.Name -contains 'errors' -and $result.errors) {
            $hasErrors = @($result.errors).Count -gt 0
        }
        $updates['runbookCompletedAt'] = $completedAt
        $wipeIssuedAt = $completedAt
        if ($result.PSObject.Properties.Name -contains 'completedAt' -and $result.completedAt) {
            try { $wipeIssuedAt = [datetime]::Parse([string]$result.completedAt).ToUniversalTime() } catch { $wipeIssuedAt = $completedAt }
        }
        $updates['wipeIssuedAt'] = $wipeIssuedAt
        $updates['deviceActionState'] = 'pending'
        $updates['deviceActionPollCount'] = 0
        $updates['deviceActionSuccessStatus'] = if ($hasErrors) { 'PartiallyCompleted' } else { 'Completed' }
    }
    else {
        $updates['completedAt'] = $completedAt
    }
    if ($result) { $updates['resultJson'] = $result }
    # Keep the raw stream as evidence when the runbook has no ##RESULT## line yet.
    elseif ($output) { $updates['rawOutput'] = ([string]$output).Substring(0, [Math]::Min(30000, ([string]$output).Length)) }

    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties $updates

    $logProps.status = $status
    if ($status -eq 'PendingDeviceAction') {
        Write-AtLog -Level 'Information' -Message 'JobMonitor: wipe command accepted; waiting asynchronously for the Intune device action.' -Properties $logProps
        Write-AtAudit -Action 'WipePendingDeviceAction' -Properties ($logProps + @{
            jobStatus = [string]$job.Status
            deviceActionState = 'pending'
            successStatus = $updates.deviceActionSuccessStatus
        })
        continue
    }

    Write-AtLog -Level 'Information' -Message 'JobMonitor: request reached a terminal state.' -Properties $logProps
    $auditLevel = if ($status -eq 'Completed') { 'Information' } elseif ($status -eq 'PartiallyCompleted') { 'Warning' } else { 'Error' }
    Write-AtAudit -Action 'WipeTerminalState' -Level $auditLevel -Properties ($logProps + @{ jobStatus = [string]$job.Status; errorMessage = $errorMessage })
    Send-RequestCallback -Request $request -Status $status -CompletedAt $completedAt -ErrorMessage $errorMessage -Result $result -LogProperties $logProps
}
