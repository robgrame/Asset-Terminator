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

    It 'dispatches the runbook when Service Bus supplies dryRun as string false' {
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

        Invoke-DisposalDispatch -Message $message -ExpectedPlatform 'Windows'

        Should -Invoke Start-AutomationRunbookJob -ModuleName AT.Dispatch -Times 1 -Exactly
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.status -eq 'Dispatched' -and $Properties.automationJobId -eq 'JOB-1'
        } -Times 1 -Exactly
    }

    It 'does not start the runbook when Service Bus supplies dryRun as string true' {
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

        Invoke-DisposalDispatch -Message $message -ExpectedPlatform 'Windows'

        Should -Invoke Start-AutomationRunbookJob -ModuleName AT.Dispatch -Times 0 -Exactly
        Should -Invoke Update-WipeRequestState -ModuleName AT.Dispatch -ParameterFilter {
            $Properties.status -eq 'Completed' -and $Properties.resultJson.dryRun -eq $true
        } -Times 1 -Exactly
    }
}
