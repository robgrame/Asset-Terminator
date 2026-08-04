#Requires -Version 7.6

# Translates one canonical intake payload into one Automation runbook job.
# It deliberately does not wait for the runbook to finish; JobMonitor
# reconciles the outcome over time in the same Function App.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/AT.Common.psm1"
Import-Module "$PSScriptRoot/AT.State.psm1"
Import-Module "$PSScriptRoot/AT.Automation.psm1"

function Invoke-DisposalDispatch {
    param(
        [Parameter(Mandatory)] $Message,
        [Parameter(Mandatory)] [string] $ExpectedPlatform
    )

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

    $logProps = @{
        requestId     = $requestId
        correlationId = [string]$payload.correlationId
        platform      = $platform
        scenario      = [string]$payload.scenario
        serialNumber  = [string]$payload.device.serialNumber
        dryRun        = $isDryRun
    }

    Write-AtLog -Level 'Information' -Message 'Dispatching disposal request.' -Properties $logProps
    Write-AtAudit -Action 'WipeDispatchStarted' -Properties $logProps

    # Retirement never removes the device from its enrollment platform. Until the
    # runbooks accept a -Scenario parameter, a retirement request must not be sent
    # to a runbook whose first action is the unenrollment.
    if (-not [bool]$payload.options.removeFromEnrollmentPlatform -and
        -not (Get-AppSettingBool -Name 'RUNBOOKS_SUPPORT_SCENARIO' -Default $false)) {
        $reason = 'Retirement scenario requires runbooks that support -Scenario; set RUNBOOKS_SUPPORT_SCENARIO=true once updated.'
        Write-AtLog -Level 'Warning' -Message $reason -Properties $logProps
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'DispatchFailed'; errorMessage = $reason
        }
        return [pscustomobject]@{
            Status = 'DispatchFailed'
            ErrorMessage = $reason
            AutomationJobName = $null
            AutomationJobId = $null
        }
    }

    $binding = Resolve-RunbookBinding -Platform $platform -Message $payload

    # Idempotent job name: replaying the message returns the existing job.
    $jobName = $requestId

    Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
        status            = 'Dispatching'
        runbook           = $binding.Runbook
        timeoutMinutes = $binding.TimeoutMinutes
        automationJobName = $jobName
        dispatchedAt      = (Get-Date).ToUniversalTime()
    }

    if ($isDryRun) {
        Write-AtLog -Level 'Information' -Message 'Dry run: runbook not started.' -Properties $logProps
        Write-AtAudit -Action 'WipeDryRunCompleted' -Properties ($logProps + @{ status = 'Completed'; runbook = $binding.Runbook })
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'Completed'
            completedAt = (Get-Date).ToUniversalTime()
            resultJson = @{ dryRun = $true; runbook = $binding.Runbook; parameters = $binding.Parameters }
        }
        return [pscustomobject]@{
            Status = 'Completed'
            ErrorMessage = ''
            AutomationJobName = $null
            AutomationJobId = $null
        }
    }

    try {
        $job = Start-AutomationRunbookJob `
            -JobName $jobName `
            -Runbook $binding.Runbook `
            -Parameters $binding.Parameters `
            -RunOn $binding.RunOn
    }
    catch {
        # Persist the failure before returning it to the HTTP caller.
        Write-AtLog -Level 'Error' -Message "Runbook dispatch failed: $($_.Exception.Message)" -Properties $logProps
        Write-AtAudit -Action 'WipeDispatchFailed' -Level 'Error' -Properties ($logProps + @{ status = 'DispatchFailed'; error = $_.Exception.Message })
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status = 'DispatchFailed'; errorMessage = $_.Exception.Message
        }
        throw
    }

    try {
        Update-WipeRequestState -Platform $platform -RequestId $requestId -Properties @{
            status            = 'Dispatched'
            automationJobName = [string]$job.JobName
            automationJobId   = [string]$job.JobId
            dispatchedAt      = (Get-Date).ToUniversalTime()
            errorMessage      = ''
        }
    }
    catch {
        Write-AtLog -Level 'Error' -Message "Runbook started, but the Dispatched state could not be persisted: $($_.Exception.Message)" -Properties $logProps
        Write-AtAudit -Action 'WipeDispatchStatePending' -Level 'Error' -Properties ($logProps + @{ status = 'Dispatching'; automationJobId = [string]$job.JobId })
        return [pscustomobject]@{
            Status = 'Dispatching'
            ErrorMessage = 'The runbook started; JobMonitor will reconcile the pending dispatch state.'
            AutomationJobName = [string]$job.JobName
            AutomationJobId = [string]$job.JobId
        }
    }

    $logProps.automationJobName = [string]$job.JobName
    Write-AtLog -Level 'Information' -Message 'Runbook job started.' -Properties $logProps
    Write-AtAudit -Action 'WipeJobStarted' -Properties ($logProps + @{ status = 'Dispatched'; runbook = $binding.Runbook; automationJobId = [string]$job.JobId })

    return [pscustomobject]@{
        Status = 'Dispatched'
        ErrorMessage = ''
        AutomationJobName = [string]$job.JobName
        AutomationJobId = [string]$job.JobId
    }
}

Export-ModuleMember -Function Invoke-DisposalDispatch
