#Requires -Version 7.6

BeforeAll {
    Import-Module "$PSScriptRoot/../shared/Modules/AT.Dispatch.psm1" -Force
}

Describe 'Invoke-DisposalDispatch dryRun handling' {
    BeforeEach {
        Mock Write-AtLog {} -ModuleName AT.Dispatch
        Mock Write-AtAudit {} -ModuleName AT.Dispatch
        Mock Get-AppSettingBool { $true } -ModuleName AT.Dispatch
        Mock Resolve-RunbookBinding {
            [pscustomobject]@{
                Runbook        = 'TestRunbook'
                Parameters     = @{}
                TimeoutMinutes = 20
                RunOn          = ''
            }
        } -ModuleName AT.Dispatch
        Mock Update-WipeRequestState {} -ModuleName AT.Dispatch
        Mock Invoke-IdempotentRunbookDispatch {
            [pscustomobject]@{
                Outcome      = 'Started'
                Job          = [pscustomobject]@{ JobName = 'REQUEST-1'; JobId = 'JOB-1'; Status = 'New' }
                ErrorMessage = ''
            }
        } -ModuleName AT.Dispatch
    }

    It 'dispatches the runbook when the intake supplies dryRun as string false' {
        $message = @{
            requestId     = 'REQUEST-1'
            correlationId = 'CORRELATION-1'
            platform      = 'Windows'
            scenario      = 'Disposal'
            device        = @{ serialNumber = 'SERIAL-1' }
            options       = @{
                removeFromEnrollmentPlatform = $true
                dryRun                       = 'false'
            }
        }

        $result = Invoke-DisposalDispatch -Message $message -ExpectedPlatform 'Windows'

        $result.Status | Should -Be 'Dispatched'
        $result.AutomationJobId | Should -Be 'JOB-1'
        $result.Terminal | Should -BeFalse
        $result.ReleaseLease | Should -BeFalse
        Should -Invoke Invoke-IdempotentRunbookDispatch -ModuleName AT.Dispatch -Times 1 -Exactly
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.status -eq 'Dispatched' -and $Properties.automationJobId -eq 'JOB-1'
        } -Times 1 -Exactly
    }

    It 'does not start the runbook when the intake supplies dryRun as string true, and arms the callback when a callbackUrl is present' {
        $message = @{
            requestId     = 'REQUEST-1'
            correlationId = 'CORRELATION-1'
            platform      = 'Windows'
            scenario      = 'Disposal'
            device        = @{ serialNumber = 'SERIAL-1' }
            callbackUrl   = 'https://servicenow.example/callback'
            options       = @{
                removeFromEnrollmentPlatform = $true
                dryRun                       = 'true'
            }
        }

        $result = Invoke-DisposalDispatch -Message $message -ExpectedPlatform 'Windows'

        $result.Status | Should -Be 'Completed'
        $result.Terminal | Should -BeTrue
        $result.ReleaseLease | Should -BeTrue
        Should -Invoke Invoke-IdempotentRunbookDispatch -ModuleName AT.Dispatch -Times 0 -Exactly
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.status -eq 'Completed' -and $Properties.resultJson.dryRun -eq $true
        } -Times 1 -Exactly
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.callbackStatus -eq 'Pending'
        } -Times 1 -Exactly
    }

    It 'does not arm a callback when the request has no callbackUrl (missing key entirely)' {
        $message = @{
            requestId     = 'REQUEST-1'
            correlationId = 'CORRELATION-1'
            platform      = 'Windows'
            scenario      = 'Disposal'
            device        = @{ serialNumber = 'SERIAL-1' }
            options       = @{ removeFromEnrollmentPlatform = $true; dryRun = 'true' }
        }

        Invoke-DisposalDispatch -Message $message -ExpectedPlatform 'Windows' | Out-Null

        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.ContainsKey('callbackStatus')
        } -Times 0 -Exactly
    }
}

Describe 'Invoke-DisposalDispatch ambiguous ARM PUT handling' {
    BeforeEach {
        Mock Write-AtLog {} -ModuleName AT.Dispatch
        Mock Write-AtAudit {} -ModuleName AT.Dispatch
        Mock Get-AppSettingBool { $true } -ModuleName AT.Dispatch
        Mock Resolve-RunbookBinding {
            [pscustomobject]@{ Runbook = 'TestRunbook'; Parameters = @{}; TimeoutMinutes = 20; RunOn = '' }
        } -ModuleName AT.Dispatch
        Mock Update-WipeRequestState {} -ModuleName AT.Dispatch

        $script:message = @{
            requestId     = 'REQUEST-2'
            correlationId = 'CORRELATION-2'
            platform      = 'Windows'
            scenario      = 'Disposal'
            device        = @{ serialNumber = 'SERIAL-2' }
            options       = @{ removeFromEnrollmentPlatform = $true; dryRun = $false }
        }
    }

    It 'schedules a backoff retry - never DispatchFailed, never releasing the lease - when the PUT is confirmed absent (safe to retry)' {
        Mock Invoke-IdempotentRunbookDispatch {
            [pscustomobject]@{ Outcome = 'ConfirmedAbsent'; Job = $null; ErrorMessage = 'ARM PUT timed out; GET confirmed no job exists yet.' }
        } -ModuleName AT.Dispatch

        $result = Invoke-DisposalDispatch -Message $script:message -ExpectedPlatform 'Windows' -Attempt 1 -MaxAttempts 5

        $result.Status | Should -Be 'Dispatching'
        $result.Terminal | Should -BeFalse
        $result.ReleaseLease | Should -BeFalse
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.status -eq 'Dispatching' -and $Properties.ContainsKey('nextAttemptAt') -and $Properties.dispatchOutcome -eq 'ConfirmedAbsent'
        } -Times 1 -Exactly
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter { $Properties.status -eq 'DispatchFailed' } -Times 0 -Exactly
    }

    It 'schedules a backoff retry when the outcome is truly Unknown (confirming GET also failed), without ever guessing' {
        Mock Invoke-IdempotentRunbookDispatch {
            [pscustomobject]@{ Outcome = 'Unknown'; Job = $null; ErrorMessage = 'PUT failed ambiguously and the confirming GET also failed.' }
        } -ModuleName AT.Dispatch

        $result = Invoke-DisposalDispatch -Message $script:message -ExpectedPlatform 'Windows' -Attempt 2 -MaxAttempts 5

        $result.Status | Should -Be 'Dispatching'
        $result.Terminal | Should -BeFalse
        $result.ReleaseLease | Should -BeFalse
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter { $Properties.status -eq 'DispatchFailed' } -Times 0 -Exactly
    }

    It 'fails terminally and releases the lease once MaxAttempts is exhausted, still for an ambiguous Unknown outcome' {
        Mock Invoke-IdempotentRunbookDispatch {
            [pscustomobject]@{ Outcome = 'Unknown'; Job = $null; ErrorMessage = 'still unknown' }
        } -ModuleName AT.Dispatch

        $result = Invoke-DisposalDispatch -Message $script:message -ExpectedPlatform 'Windows' -Attempt 3 -MaxAttempts 3

        $result.Status | Should -Be 'DispatchFailed'
        $result.Terminal | Should -BeTrue
        $result.ReleaseLease | Should -BeTrue
        $result.ErrorMessage | Should -Match 'Manual verification'
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.status -eq 'DispatchFailed' -and $Properties.dispatchOutcome -eq 'Unknown'
        } -Times 1 -Exactly
    }

    It 'fails terminally once MaxAttempts is exhausted for a PermanentFailure outcome' {
        Mock Invoke-IdempotentRunbookDispatch {
            [pscustomobject]@{ Outcome = 'PermanentFailure'; Job = $null; ErrorMessage = 'RBAC denied' }
        } -ModuleName AT.Dispatch

        $result = Invoke-DisposalDispatch -Message $script:message -ExpectedPlatform 'Windows' -Attempt 4 -MaxAttempts 4

        $result.Status | Should -Be 'DispatchFailed'
        $result.Terminal | Should -BeTrue
        $result.ReleaseLease | Should -BeTrue
    }

    It 'confirms a successful dispatch when the ambiguous PUT is later found Started by the GET' {
        Mock Invoke-IdempotentRunbookDispatch {
            [pscustomobject]@{ Outcome = 'Started'; Job = [pscustomobject]@{ JobName = 'REQUEST-2'; JobId = 'JOB-9' }; ErrorMessage = '' }
        } -ModuleName AT.Dispatch

        $result = Invoke-DisposalDispatch -Message $script:message -ExpectedPlatform 'Windows' -Attempt 1

        $result.Status | Should -Be 'Dispatched'
        $result.AutomationJobId | Should -Be 'JOB-9'
    }
}

Describe 'Invoke-DispatchClaim' {
    It 'claims a request whose row is Accepted' {
        Mock Get-WipeRequestStateWithETag {
            [pscustomobject]@{ Entity = [pscustomobject]@{ status = 'Accepted' }; ETag = 'W/"etag-1"' }
        } -ModuleName AT.Dispatch
        Mock Set-WipeRequestStateClaim { $true } -ModuleName AT.Dispatch

        $claim = Invoke-DispatchClaim -Platform 'Windows' -RequestId 'REQUEST-3'

        $claim.Claimed | Should -BeTrue
        Should -Invoke Set-WipeRequestStateClaim -ModuleName AT.Dispatch -ParameterFilter { $ETag -eq 'W/"etag-1"' } -Times 1 -Exactly
    }

    It 'does not claim a row already owned by another worker (ETag conflict)' {
        Mock Get-WipeRequestStateWithETag {
            [pscustomobject]@{ Entity = [pscustomobject]@{ status = 'Dispatching' }; ETag = 'W/"etag-2"' }
        } -ModuleName AT.Dispatch
        Mock Set-WipeRequestStateClaim { $false } -ModuleName AT.Dispatch

        $claim = Invoke-DispatchClaim -Platform 'Windows' -RequestId 'REQUEST-4'

        $claim.Claimed | Should -BeFalse
        $claim.Reason | Should -Be 'ClaimConflict'
    }

    It 'refuses to claim a row that is not in a dispatchable status' {
        Mock Get-WipeRequestStateWithETag {
            [pscustomobject]@{ Entity = [pscustomobject]@{ status = 'Completed' }; ETag = 'W/"etag-3"' }
        } -ModuleName AT.Dispatch
        Mock Set-WipeRequestStateClaim {} -ModuleName AT.Dispatch

        $claim = Invoke-DispatchClaim -Platform 'Windows' -RequestId 'REQUEST-5'

        $claim.Claimed | Should -BeFalse
        $claim.Reason | Should -Be 'NotEligible'
        Should -Invoke Set-WipeRequestStateClaim -ModuleName AT.Dispatch -Times 0 -Exactly
    }
}

Describe 'Invoke-DispatchReconciliation (JobMonitor crash recovery)' {
    It 'reconciles an Accepted request after a crash by rebuilding the payload from payloadJson and dispatching it' {
        $canonicalMessage = @{
            requestId = 'REQUEST-6'; correlationId = 'CORR-6'; platform = 'Windows'; scenario = 'Disposal'
            device    = @{ serialNumber = 'SERIAL-6' }
            options   = @{ removeFromEnrollmentPlatform = $true; dryRun = $false }
        } | ConvertTo-Json -Depth 6

        Mock Invoke-DispatchClaim {
            [pscustomobject]@{
                Claimed = $true; Reason = ''
                Entity  = [pscustomobject]@{ PartitionKey = 'Windows'; RowKey = 'REQUEST-6'; payloadJson = $canonicalMessage }
            }
        } -ModuleName AT.Dispatch
        Mock Invoke-DisposalDispatch {
            [pscustomobject]@{ Status = 'Dispatched'; ErrorMessage = ''; AutomationJobName = 'REQUEST-6'; AutomationJobId = 'JOB-6'; Attempt = 1; Terminal = $false; ReleaseLease = $false }
        } -ModuleName AT.Dispatch

        $request = [pscustomobject]@{ PartitionKey = 'Windows'; RowKey = 'REQUEST-6' }
        $reconciliation = Invoke-DispatchReconciliation -Request $request

        $reconciliation.Claimed | Should -BeTrue
        $reconciliation.Result.Status | Should -Be 'Dispatched'
        Should -Invoke Invoke-DisposalDispatch -ModuleName AT.Dispatch -ParameterFilter { $Attempt -eq 1 -and $ExpectedPlatform -eq 'Windows' } -Times 1 -Exactly
    }

    It 'increments the attempt number from the row''s persisted attempts count' {
        $canonicalMessage = @{ requestId = 'REQUEST-7'; platform = 'Windows' } | ConvertTo-Json

        Mock Invoke-DispatchClaim {
            [pscustomobject]@{
                Claimed = $true; Reason = ''
                Entity  = [pscustomobject]@{ PartitionKey = 'Windows'; RowKey = 'REQUEST-7'; payloadJson = $canonicalMessage; attempts = '2' }
            }
        } -ModuleName AT.Dispatch
        Mock Invoke-DisposalDispatch { [pscustomobject]@{ Status = 'Dispatching'; Terminal = $false; ReleaseLease = $false } } -ModuleName AT.Dispatch

        Invoke-DispatchReconciliation -Request ([pscustomobject]@{ PartitionKey = 'Windows'; RowKey = 'REQUEST-7' }) | Out-Null

        Should -Invoke Invoke-DisposalDispatch -ModuleName AT.Dispatch -ParameterFilter { $Attempt -eq 3 } -Times 1 -Exactly
    }

    It 'skips the row cleanly when the claim is lost to another worker' {
        Mock Invoke-DispatchClaim { [pscustomobject]@{ Claimed = $false; Reason = 'ClaimConflict'; Entity = $null } } -ModuleName AT.Dispatch
        Mock Invoke-DisposalDispatch {} -ModuleName AT.Dispatch

        $reconciliation = Invoke-DispatchReconciliation -Request ([pscustomobject]@{ PartitionKey = 'Windows'; RowKey = 'REQUEST-8' })

        $reconciliation.Claimed | Should -BeFalse
        $reconciliation.Result | Should -BeNullOrEmpty
        Should -Invoke Invoke-DisposalDispatch -ModuleName AT.Dispatch -Times 0 -Exactly
    }

    It 'fails terminally without throwing when the claimed row has no usable payloadJson' {
        Mock Invoke-DispatchClaim {
            [pscustomobject]@{ Claimed = $true; Reason = ''; Entity = [pscustomobject]@{ PartitionKey = 'Windows'; RowKey = 'REQUEST-9' } }
        } -ModuleName AT.Dispatch
        Mock Update-WipeRequestState {} -ModuleName AT.Dispatch
        Mock Write-AtLog {} -ModuleName AT.Dispatch

        $reconciliation = Invoke-DispatchReconciliation -Request ([pscustomobject]@{ PartitionKey = 'Windows'; RowKey = 'REQUEST-9' })

        $reconciliation.Claimed | Should -BeTrue
        $reconciliation.Result.Status | Should -Be 'DispatchFailed'
        $reconciliation.Result.Terminal | Should -BeTrue
    }
}

