#Requires -Version 7.6

# End-to-end test of the full asynchronous, non-dryRun lifecycle using an
# in-memory fake Table Storage (no real Azure calls): WipeIntake's durable
# Accepted row -> JobMonitor dispatch reconciliation (claim + ARM PUT) ->
# in-flight reconciliation (job polling + evidence) -> callback reconciliation.
# Everything that would touch Azure (ARM, Automation, the ServiceNow callback)
# is mocked; everything else (claims, backoff bookkeeping, state transitions)
# runs for real against the fake store.

BeforeAll {
    Import-Module "$PSScriptRoot/../shared/Modules/AT.Dispatch.psm1" -Force

    function Get-FakeKey { param($Platform, $RequestId) "$Platform::$RequestId" }

    function Set-FakeEntity {
        param($Platform, $RequestId, [hashtable] $Properties)
        $key = Get-FakeKey $Platform $RequestId
        if (-not $script:FakeStore.ContainsKey($key)) {
            $script:FakeStore[$key] = @{ Entity = [ordered]@{ PartitionKey = $Platform; RowKey = $RequestId }; Version = 0 }
        }
        $entry = $script:FakeStore[$key]
        foreach ($k in $Properties.Keys) {
            $v = $Properties[$k]
            if ($null -eq $v) { continue }
            if ($v -is [hashtable] -or $v -is [pscustomobject] -or $v -is [array]) {
                $entry.Entity[$k] = ($v | ConvertTo-Json -Depth 10 -Compress)
            }
            elseif ($v -is [datetime]) {
                $entry.Entity[$k] = $v.ToUniversalTime().ToString('o')
            }
            else {
                $entry.Entity[$k] = $v
            }
        }
        $entry.Version++
    }

    function Get-FakeEntity {
        param($Platform, $RequestId)
        $key = Get-FakeKey $Platform $RequestId
        if (-not $script:FakeStore.ContainsKey($key)) { return $null }
        return [pscustomobject]$script:FakeStore[$key].Entity
    }
}

Describe 'E2E (mocked): full asynchronous non-dryRun lifecycle' {
    BeforeEach {
        $script:FakeStore = @{}

        Mock Write-AtLog {} -ModuleName AT.Dispatch
        Mock Write-AtAudit {} -ModuleName AT.Dispatch
        Mock Get-AppSettingBool { $true } -ModuleName AT.Dispatch
        Mock Get-EvidenceMaxAttempts { 5 } -ModuleName AT.Dispatch
        Mock Get-CallbackMaxAttempts { 6 } -ModuleName AT.Dispatch
        Mock Resolve-RunbookBinding {
            [pscustomobject]@{ Runbook = 'RBK-WindowsDisposal'; Parameters = @{}; TimeoutMinutes = 30; RunOn = '' }
        } -ModuleName AT.Dispatch

        Mock Update-WipeRequestState {
            Set-FakeEntity -Platform $Platform -RequestId $RequestId -Properties $Properties
        } -ModuleName AT.Dispatch

        Mock Get-WipeRequestStateWithETag {
            $entity = Get-FakeEntity -Platform $Platform -RequestId $RequestId
            if (-not $entity) { return $null }
            $key = Get-FakeKey $Platform $RequestId
            return [pscustomobject]@{ Entity = $entity; ETag = "W/`"$($script:FakeStore[$key].Version)`"" }
        } -ModuleName AT.Dispatch

        Mock Set-WipeRequestStateClaim {
            Set-FakeEntity -Platform $Platform -RequestId $RequestId -Properties $Properties
            return $true
        } -ModuleName AT.Dispatch

        # --- WipeIntake's durable handoff: persist Accepted with the full canonical payload ---
        $script:canonicalMessage = [ordered]@{
            schemaVersion = '1.0'
            requestId     = 'E2E-REQUEST-1'
            correlationId = 'E2E-CORR-1'
            platform      = 'Windows'
            scenario      = 'Disposal'
            device        = [ordered]@{ serialNumber = 'E2E-SERIAL-1'; managedDeviceId = 'dev-e2e-1'; deviceName = 'E2E-DEVICE-1' }
            options       = [ordered]@{ removeFromEnrollmentPlatform = $true; dryRun = $false }
            callbackUrl   = 'https://servicenow.example/callback'
        }

        Set-FakeEntity -Platform 'Windows' -RequestId 'E2E-REQUEST-1' -Properties @{
            status       = 'Accepted'
            correlationId = 'E2E-CORR-1'
            serialNumber = 'E2E-SERIAL-1'
            callbackUrl  = 'https://servicenow.example/callback'
            dryRun       = $false
            attempts     = 0
            payloadJson  = ($script:canonicalMessage | ConvertTo-Json -Depth 10)
        }
    }

    It 'dispatches, monitors, and delivers the callback for a non-dryRun request end to end' {
        # --- Step 1: JobMonitor's dispatch pass reconciles the durable Accepted row ---
        Mock Invoke-IdempotentRunbookDispatch {
            [pscustomobject]@{
                Outcome = 'Started'
                Job     = [pscustomobject]@{ JobName = 'E2E-REQUEST-1'; JobId = 'JOB-E2E-1'; Status = 'New' }
                ErrorMessage = ''
            }
        } -ModuleName AT.Dispatch

        $request = Get-FakeEntity -Platform 'Windows' -RequestId 'E2E-REQUEST-1'
        $dispatchReconciliation = Invoke-DispatchReconciliation -Request $request

        $dispatchReconciliation.Claimed | Should -BeTrue
        $dispatchReconciliation.Result.Status | Should -Be 'Dispatched'
        (Get-FakeEntity -Platform 'Windows' -RequestId 'E2E-REQUEST-1').status | Should -Be 'Dispatched'
        (Get-FakeEntity -Platform 'Windows' -RequestId 'E2E-REQUEST-1').automationJobId | Should -Be 'JOB-E2E-1'

        # --- Step 2: in-flight reconciliation while the job is still running ---
        Mock Get-AutomationRunbookJob { [pscustomobject]@{ JobName = 'E2E-REQUEST-1'; JobId = 'JOB-E2E-1'; Status = 'Running' } } -ModuleName AT.Dispatch

        $request = Get-FakeEntity -Platform 'Windows' -RequestId 'E2E-REQUEST-1'
        $inFlight1 = Invoke-InFlightReconciliation -Request $request

        $inFlight1.Handled | Should -BeFalse
        (Get-FakeEntity -Platform 'Windows' -RequestId 'E2E-REQUEST-1').status | Should -Be 'Running'

        # --- Step 3: the job completes with a valid ##RESULT## line ---
        Mock Get-AutomationRunbookJob { [pscustomobject]@{ JobName = 'E2E-REQUEST-1'; JobId = 'JOB-E2E-1'; Status = 'Completed' } } -ModuleName AT.Dispatch
        Mock Get-AutomationRunbookJobOutput { "Autopilot delete OK`n##RESULT## {`"wipeIssued`":true,`"dryRun`":false,`"errors`":[]}" } -ModuleName AT.Dispatch

        $request = Get-FakeEntity -Platform 'Windows' -RequestId 'E2E-REQUEST-1'
        $inFlight2 = Invoke-InFlightReconciliation -Request $request

        $inFlight2.Status | Should -Be 'Completed'
        $inFlight2.EvidenceState | Should -Be 'HasResult'
        $inFlight2.ReleaseLease | Should -BeTrue
        $inFlight2.CallbackEventId | Should -Not -BeNullOrEmpty

        $terminalEntity = Get-FakeEntity -Platform 'Windows' -RequestId 'E2E-REQUEST-1'
        $terminalEntity.status | Should -Be 'Completed'
        $terminalEntity.callbackStatus | Should -Be 'Pending'

        # --- Step 4: callback reconciliation delivers the durable callback ---
        Mock Send-WipeRequestCallback {} -ModuleName AT.Dispatch

        $request = Get-FakeEntity -Platform 'Windows' -RequestId 'E2E-REQUEST-1'
        $callbackReconciliation = Invoke-CallbackReconciliation -Request $request

        $callbackReconciliation.Claimed | Should -BeTrue
        $callbackReconciliation.Outcome | Should -Be 'Sent'
        Should -Invoke Send-WipeRequestCallback -ModuleName AT.Dispatch -ParameterFilter {
            $Payload.requestId -eq 'E2E-REQUEST-1' -and $Payload.eventId -eq $inFlight2.CallbackEventId
        } -Times 1 -Exactly

        (Get-FakeEntity -Platform 'Windows' -RequestId 'E2E-REQUEST-1').callbackStatus | Should -Be 'Sent'
    }

    It 'recovers a crashed dispatch (Accepted, never attempted) purely from the durable payload' {
        Mock Invoke-IdempotentRunbookDispatch {
            [pscustomobject]@{ Outcome = 'Started'; Job = [pscustomobject]@{ JobName = 'E2E-REQUEST-1'; JobId = 'JOB-RECOVERED' }; ErrorMessage = '' }
        } -ModuleName AT.Dispatch

        # Simulate the Function App having crashed right after WipeIntake wrote
        # the Accepted row: no attempt has happened yet (attempts still 0).
        (Get-FakeEntity -Platform 'Windows' -RequestId 'E2E-REQUEST-1').status | Should -Be 'Accepted'

        $request = Get-FakeEntity -Platform 'Windows' -RequestId 'E2E-REQUEST-1'
        $reconciliation = Invoke-DispatchReconciliation -Request $request

        $reconciliation.Result.Status | Should -Be 'Dispatched'
        $reconciliation.Result.AutomationJobId | Should -Be 'JOB-RECOVERED'
    }
}
