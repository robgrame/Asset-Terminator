#Requires -Version 7.6

BeforeAll {
    Import-Module "$PSScriptRoot/../shared/Modules/AT.Dispatch.psm1" -Force
}

Describe 'Invoke-InFlightReconciliation' {
    BeforeEach {
        Mock Write-AtLog {} -ModuleName AT.Dispatch
        Mock Write-AtAudit {} -ModuleName AT.Dispatch
        Mock Update-WipeRequestState {} -ModuleName AT.Dispatch
        Mock Get-EvidenceMaxAttempts { 3 } -ModuleName AT.Dispatch
    }

    BeforeAll {
        function New-InFlightRequest {
            param(
                [string] $Status = 'Dispatched',
                [string] $JobName = 'REQUEST-J1',
                [Nullable[datetime]] $DispatchedAt = (Get-Date).ToUniversalTime(),
                [int] $TimeoutMinutes = 60,
                [string] $EvidenceAttempts,
                [string] $CallbackUrl
            )
            $entity = [ordered]@{
                PartitionKey      = 'Windows'
                RowKey            = 'REQUEST-J1'
                status            = $Status
                automationJobName = $JobName
                timeoutMinutes    = $TimeoutMinutes
                serialNumber      = 'SERIAL-J1'
            }
            if ($DispatchedAt) { $entity['dispatchedAt'] = $DispatchedAt.ToString('o') }
            if ($EvidenceAttempts) { $entity['evidenceAttempts'] = $EvidenceAttempts }
            if ($CallbackUrl) { $entity['callbackUrl'] = $CallbackUrl }
            return [pscustomobject]$entity
        }
    }

    It 'declares success only when a valid ##RESULT## line is present (HasResult)' {
        Mock Get-AutomationRunbookJob { [pscustomobject]@{ JobName = 'REQUEST-J1'; JobId = 'JOB-1'; Status = 'Completed' } } -ModuleName AT.Dispatch
        Mock Get-AutomationRunbookJobOutput { "some log`n##RESULT## {`"wipeIssued`":true}" } -ModuleName AT.Dispatch

        $result = Invoke-InFlightReconciliation -Request (New-InFlightRequest)

        $result.Status | Should -Be 'Completed'
        $result.EvidenceState | Should -Be 'HasResult'
        $result.ReleaseLease | Should -BeTrue
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter { $Properties.status -eq 'Completed' } -Times 1 -Exactly
    }

    It 'retries as EvidencePending when the job is terminal but produced no output yet' {
        Mock Get-AutomationRunbookJob { [pscustomobject]@{ JobName = 'REQUEST-J1'; JobId = 'JOB-1'; Status = 'Completed' } } -ModuleName AT.Dispatch
        Mock Get-AutomationRunbookJobOutput { '' } -ModuleName AT.Dispatch

        $result = Invoke-InFlightReconciliation -Request (New-InFlightRequest -EvidenceAttempts '0')

        $result.Status | Should -Be 'EvidencePending'
        $result.EvidenceState | Should -Be 'EvidencePending'
        $result.ReleaseLease | Should -BeFalse
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.status -eq 'EvidencePending' -and $Properties.evidenceAttempts -eq 1
        } -Times 1 -Exactly
    }

    It 'retries as EvidencePending when the output has no usable ##RESULT## line (unparseable/missing marker)' {
        Mock Get-AutomationRunbookJob { [pscustomobject]@{ JobName = 'REQUEST-J1'; JobId = 'JOB-1'; Status = 'Completed' } } -ModuleName AT.Dispatch
        Mock Get-AutomationRunbookJobOutput { 'runbook finished but forgot to emit the marker line' } -ModuleName AT.Dispatch

        $result = Invoke-InFlightReconciliation -Request (New-InFlightRequest -EvidenceAttempts '1')

        $result.Status | Should -Be 'EvidencePending'
        $result.EvidenceState | Should -Be 'EvidenceMissing'
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter { $Properties.evidenceAttempts -eq 2 } -Times 1 -Exactly
    }

    It 'fails the request with evidenceState=EvidenceMissing once the evidence retry budget is exhausted' {
        Mock Get-AutomationRunbookJob { [pscustomobject]@{ JobName = 'REQUEST-J1'; JobId = 'JOB-1'; Status = 'Completed' } } -ModuleName AT.Dispatch
        Mock Get-AutomationRunbookJobOutput { '' } -ModuleName AT.Dispatch

        $result = Invoke-InFlightReconciliation -Request (New-InFlightRequest -EvidenceAttempts '2' -CallbackUrl 'https://servicenow.example/callback')

        $result.Status | Should -Be 'Failed'
        $result.EvidenceState | Should -Be 'EvidenceMissing'
        $result.ReleaseLease | Should -BeTrue
        $result.CallbackEventId | Should -Not -BeNullOrEmpty
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.status -eq 'Failed' -and $Properties.evidenceState -eq 'EvidenceMissing'
        } -Times 1 -Exactly
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter { $Properties.callbackStatus -eq 'Pending' } -Times 1 -Exactly
    }

    It 'fails the request as Failed/EvidenceMissing on overall timeout while the job is still running' {
        Mock Get-AutomationRunbookJob { [pscustomobject]@{ JobName = 'REQUEST-J1'; JobId = 'JOB-1'; Status = 'Running' } } -ModuleName AT.Dispatch

        $result = Invoke-InFlightReconciliation -Request (New-InFlightRequest -Status 'Running' -DispatchedAt ((Get-Date).ToUniversalTime().AddMinutes(-120)) -TimeoutMinutes 60)

        $result.Status | Should -Be 'Failed'
        $result.EvidenceState | Should -Be 'EvidenceMissing'
        $result.ReleaseLease | Should -BeTrue
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.status -eq 'Failed' -and $Properties.evidenceState -eq 'EvidenceMissing'
        } -Times 1 -Exactly
    }

    It 'updates progress to Running without touching evidence state while still legitimately in progress' {
        Mock Get-AutomationRunbookJob { [pscustomobject]@{ JobName = 'REQUEST-J1'; JobId = 'JOB-1'; Status = 'Running' } } -ModuleName AT.Dispatch

        $result = Invoke-InFlightReconciliation -Request (New-InFlightRequest -Status 'Dispatched' -DispatchedAt ((Get-Date).ToUniversalTime()) -TimeoutMinutes 60)

        $result.Handled | Should -BeFalse
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter { $Properties.status -eq 'Running' } -Times 1 -Exactly
    }
}

Describe 'Invoke-CallbackReconciliation (durable callback delivery)' {
    BeforeEach {
        Mock Write-AtLog {} -ModuleName AT.Dispatch
        Mock Write-AtAudit {} -ModuleName AT.Dispatch
        Mock Update-WipeRequestState {} -ModuleName AT.Dispatch
        Mock Set-WipeRequestStateClaim { $true } -ModuleName AT.Dispatch
        Mock Get-CallbackMaxAttempts { 3 } -ModuleName AT.Dispatch
    }

    BeforeAll {
        function New-CallbackRow {
            param(
                [string] $CallbackStatus = 'Pending',
                [string] $CallbackAttempts,
                [string] $EventId,
                [string] $Status = 'Completed',
                [string] $DryRun = 'False',
                [string] $CallbackUrl = 'https://servicenow.example/callback'
            )
            $entity = [ordered]@{
                PartitionKey   = 'Windows'; RowKey = 'REQUEST-C1'
                callbackStatus = $CallbackStatus
                callbackUrl    = $CallbackUrl
                status         = $Status
                dryRun         = $DryRun
            }
            if ($CallbackAttempts) { $entity['callbackAttempts'] = $CallbackAttempts }
            if ($EventId) { $entity['eventId'] = $EventId }
            return [pscustomobject]$entity
        }
    }

    It 'delivers a pending callback and marks it Sent, including a dryRun completion' {
        Mock Get-WipeRequestStateWithETag {
            [pscustomobject]@{ Entity = (New-CallbackRow -DryRun 'True'); ETag = 'W/"etag-c1"' }
        } -ModuleName AT.Dispatch
        Mock Send-WipeRequestCallback {} -ModuleName AT.Dispatch

        $reconciliation = Invoke-CallbackReconciliation -Request ([pscustomobject]@{ PartitionKey = 'Windows'; RowKey = 'REQUEST-C1' })

        $reconciliation.Claimed | Should -BeTrue
        $reconciliation.Outcome | Should -Be 'Sent'
        Should -Invoke Send-WipeRequestCallback -ModuleName AT.Dispatch -ParameterFilter { $Payload.dryRun -eq 'True' } -Times 1 -Exactly
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter { $Properties.callbackStatus -eq 'Sent' } -Times 1 -Exactly
    }

    It 'schedules a retry with backoff (FailedRetryable) when delivery fails and attempts remain' {
        Mock Get-WipeRequestStateWithETag {
            [pscustomobject]@{ Entity = (New-CallbackRow -CallbackAttempts '0'); ETag = 'W/"etag-c2"' }
        } -ModuleName AT.Dispatch
        Mock Send-WipeRequestCallback { throw 'network error' } -ModuleName AT.Dispatch

        $reconciliation = Invoke-CallbackReconciliation -Request ([pscustomobject]@{ PartitionKey = 'Windows'; RowKey = 'REQUEST-C1' })

        $reconciliation.Outcome | Should -Be 'FailedRetryable'
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.callbackStatus -eq 'FailedRetryable' -and $Properties.ContainsKey('callbackNextAttemptAt')
        } -Times 1 -Exactly
    }

    It 'marks the callback Failed terminally once CALLBACK_MAX_ATTEMPTS is exhausted' {
        Mock Get-WipeRequestStateWithETag {
            [pscustomobject]@{ Entity = (New-CallbackRow -CallbackStatus 'FailedRetryable' -CallbackAttempts '2'); ETag = 'W/"etag-c3"' }
        } -ModuleName AT.Dispatch
        Mock Send-WipeRequestCallback { throw 'still failing' } -ModuleName AT.Dispatch

        $reconciliation = Invoke-CallbackReconciliation -Request ([pscustomobject]@{ PartitionKey = 'Windows'; RowKey = 'REQUEST-C1' })

        $reconciliation.Outcome | Should -Be 'Failed'
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter { $Properties.callbackStatus -eq 'Failed' } -Times 1 -Exactly
    }

    It 'reuses the same eventId across retries for the receiver''s idempotency check' {
        Mock Get-WipeRequestStateWithETag {
            [pscustomobject]@{ Entity = (New-CallbackRow -CallbackStatus 'FailedRetryable' -CallbackAttempts '1' -EventId 'EVENT-STABLE-1'); ETag = 'W/"etag-c4"' }
        } -ModuleName AT.Dispatch
        Mock Send-WipeRequestCallback {} -ModuleName AT.Dispatch

        Invoke-CallbackReconciliation -Request ([pscustomobject]@{ PartitionKey = 'Windows'; RowKey = 'REQUEST-C1' }) | Out-Null

        Should -Invoke Send-WipeRequestCallback -ModuleName AT.Dispatch -ParameterFilter { $EventId -eq 'EVENT-STABLE-1' } -Times 1 -Exactly
    }

    It 'skips the row cleanly when the ETag claim is lost to another worker' {
        Mock Get-WipeRequestStateWithETag {
            [pscustomobject]@{ Entity = (New-CallbackRow); ETag = 'W/"etag-c5"' }
        } -ModuleName AT.Dispatch
        Mock Set-WipeRequestStateClaim { $false } -ModuleName AT.Dispatch
        Mock Send-WipeRequestCallback {} -ModuleName AT.Dispatch

        $reconciliation = Invoke-CallbackReconciliation -Request ([pscustomobject]@{ PartitionKey = 'Windows'; RowKey = 'REQUEST-C1' })

        $reconciliation.Claimed | Should -BeFalse
        Should -Invoke Send-WipeRequestCallback -ModuleName AT.Dispatch -Times 0 -Exactly
    }
}
