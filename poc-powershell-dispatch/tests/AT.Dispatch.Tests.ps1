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
        Mock Start-AutomationRunbookJob {
            [pscustomobject]@{
                JobName = 'REQUEST-1'
                JobId   = 'JOB-1'
                Status  = 'New'
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
        Should -Invoke Start-AutomationRunbookJob -ModuleName AT.Dispatch -Times 1 -Exactly
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.status -eq 'Dispatched' -and $Properties.automationJobId -eq 'JOB-1'
        } -Times 1 -Exactly
    }

    It 'does not start the runbook when the intake supplies dryRun as string true' {
        $message = @{
            requestId     = 'REQUEST-1'
            correlationId = 'CORRELATION-1'
            platform      = 'Windows'
            scenario      = 'Disposal'
            device        = @{ serialNumber = 'SERIAL-1' }
            options       = @{
                removeFromEnrollmentPlatform = $true
                dryRun                       = 'true'
            }
        }

        $result = Invoke-DisposalDispatch -Message $message -ExpectedPlatform 'Windows'

        $result.Status | Should -Be 'Completed'
        Should -Invoke Start-AutomationRunbookJob -ModuleName AT.Dispatch -Times 0 -Exactly
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.status -eq 'Completed' -and $Properties.resultJson.dryRun -eq $true
        } -Times 1 -Exactly
    }

    It 'returns Dispatching when the job starts but the final state update fails' {
        Mock Update-WipeRequestState {
            param($Platform, $RequestId, $Properties)
            if ($Properties.status -eq 'Dispatched') { throw 'Table write failed' }
        } -ModuleName AT.Dispatch

        $message = @{
            requestId     = 'REQUEST-1'
            correlationId = 'CORRELATION-1'
            platform      = 'Windows'
            scenario      = 'Disposal'
            device        = @{ serialNumber = 'SERIAL-1' }
            options       = @{
                removeFromEnrollmentPlatform = $true
                dryRun                       = $false
            }
        }

        $result = Invoke-DisposalDispatch -Message $message -ExpectedPlatform 'Windows'

        $result.Status | Should -Be 'Dispatching'
        $result.AutomationJobId | Should -Be 'JOB-1'
        Should -Invoke Start-AutomationRunbookJob -ModuleName AT.Dispatch -Times 1 -Exactly
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.status -eq 'Dispatching' -and $Properties.automationJobName -eq 'REQUEST-1'
        } -Times 1 -Exactly
    }
}
