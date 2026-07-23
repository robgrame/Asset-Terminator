#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulesDir = Join-Path $PSScriptRoot '..' 'modules'
    $orchModulesDir = Join-Path $PSScriptRoot '..' 'orchestrator' 'Modules'
    foreach ($dir in @($modulesDir, $orchModulesDir)) {
        if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $dir) {
            $env:PSModulePath = $dir + [IO.Path]::PathSeparator + $env:PSModulePath
        }
    }
    Import-Module 'AT.Common' -Force
    Import-Module 'AT.Contracts' -Force
    Import-Module 'AT.Core' -Force
    Import-Module 'AT.Infrastructure' -Force
    Import-Module 'AT.Guardrails' -Force
    Import-Module 'AT.Providers.Intune' -Force
    Import-Module 'AT.Providers.EntraId' -Force
    Import-Module 'AT.Orchestrator.Support' -Force

    function New-Action { param($Target, $Status, $Details)
        $o = [pscustomobject]@{ target = $Target; status = $Status }
        if ($PSBoundParameters.ContainsKey('Details')) { $o | Add-Member -NotePropertyName 'details' -NotePropertyValue $Details -Force }
        $o
    }
}

Describe 'Target classification' {
    It 'recognizes object-delete targets' {
        Test-IsObjectDeleteTarget -Target 'Intune' | Should -BeTrue
        Test-IsObjectDeleteTarget -Target 'EntraId' | Should -BeTrue
        Test-IsObjectDeleteTarget -Target 'ActiveDirectory' | Should -BeTrue
        Test-IsObjectDeleteTarget -Target 'ConfigMgr' | Should -BeTrue
    }
    It 'excludes Autopilot/Wipe from plain object-delete' {
        Test-IsObjectDeleteTarget -Target 'Autopilot' | Should -BeFalse
        Test-IsObjectDeleteTarget -Target 'Wipe' | Should -BeFalse
    }
    It 'includes Autopilot in object-delete-or-autopilot' {
        Test-IsObjectDeleteOrAutopilotTarget -Target 'Autopilot' | Should -BeTrue
        Test-IsObjectDeleteOrAutopilotTarget -Target 'Intune' | Should -BeTrue
        Test-IsObjectDeleteOrAutopilotTarget -Target 'Wipe' | Should -BeFalse
    }
    It 'recognizes pre-wipe gating targets' {
        Test-IsPreWipeGatingTarget -Target 'LicenseRemoval' | Should -BeTrue
        Test-IsPreWipeGatingTarget -Target 'BiosPasswordRemoval' | Should -BeTrue
        Test-IsPreWipeGatingTarget -Target 'Intune' | Should -BeFalse
    }
    It 'recognizes on-prem delete targets' {
        Test-IsOnPremDeleteTarget -Target 'ActiveDirectory' | Should -BeTrue
        Test-IsOnPremDeleteTarget -Target 'ConfigMgr' | Should -BeTrue
        Test-IsOnPremDeleteTarget -Target 'LicenseRemoval' | Should -BeTrue
        Test-IsOnPremDeleteTarget -Target 'BiosPasswordRemoval' | Should -BeTrue
        Test-IsOnPremDeleteTarget -Target 'Intune' | Should -BeFalse
    }
    It 'recognizes terminal action statuses' {
        'Success', 'Skipped', 'Failed', 'Blocked', 'TimedOut' | ForEach-Object {
            Test-IsTerminalActionStatus -Status $_ | Should -BeTrue
        }
        Test-IsTerminalActionStatus -Status 'InProgress' | Should -BeFalse
        Test-IsTerminalActionStatus -Status 'Pending' | Should -BeFalse
    }
}

Describe 'Get-OverallState' {
    It 'returns Completed when all actions succeeded or skipped' {
        Get-OverallState -Actions @((New-Action 'Intune' 'Success'), (New-Action 'EntraId' 'Skipped')) | Should -Be 'Completed'
    }
    It 'returns Completed for no actions' {
        Get-OverallState -Actions @() | Should -Be 'Completed'
    }
    It 'returns InProgress when any action is pending or in progress' {
        Get-OverallState -Actions @((New-Action 'Intune' 'Success'), (New-Action 'Wipe' 'InProgress')) | Should -Be 'InProgress'
    }
    It 'returns PartiallyCompleted on a mix of success and failure' {
        Get-OverallState -Actions @((New-Action 'Intune' 'Success'), (New-Action 'Wipe' 'Failed')) | Should -Be 'PartiallyCompleted'
    }
    It 'returns Failed when every action failed' {
        Get-OverallState -Actions @((New-Action 'Intune' 'Failed'), (New-Action 'Wipe' 'Failed')) | Should -Be 'Failed'
    }
}

Describe 'Get-ActionUpdateFromResult' {
    It 'maps success to a terminal Success outcome' {
        $u = Get-ActionUpdateFromResult -Result ([pscustomobject]@{ Status = 'Success'; Transient = $false })
        $u.Status | Should -Be 'Success'
        $u.FinalOutcome | Should -Be 'Success'
    }
    It 'maps skipped to a terminal Skipped outcome' {
        $u = Get-ActionUpdateFromResult -Result ([pscustomobject]@{ Status = 'Skipped'; Transient = $false })
        $u.Status | Should -Be 'Skipped'
        $u.FinalOutcome | Should -Be 'Skipped'
    }
    It 'keeps transient failures as InProgress for the poller to retry' {
        $u = Get-ActionUpdateFromResult -Result ([pscustomobject]@{ Status = 'Failed'; Transient = $true })
        $u.Status | Should -Be 'InProgress'
        $u.FinalOutcome | Should -BeNullOrEmpty
    }
    It 'makes hard failures terminal' {
        $u = Get-ActionUpdateFromResult -Result ([pscustomobject]@{ Status = 'Failed'; Transient = $false })
        $u.Status | Should -Be 'Failed'
        $u.FinalOutcome | Should -Be 'Failed'
    }
}

Describe 'Get-PreWipeStatus' {
    It 'reports all-succeeded when every action is success/skipped' {
        $s = Get-PreWipeStatus -Actions @((New-Action 'LicenseRemoval' 'Success'), (New-Action 'BiosPasswordRemoval' 'Skipped'))
        $s.AllTerminal | Should -BeTrue
        $s.AllSucceeded | Should -BeTrue
        $s.FailedReasons.Count | Should -Be 0
    }
    It 'reports not-terminal while an action is in progress' {
        $s = Get-PreWipeStatus -Actions @((New-Action 'LicenseRemoval' 'InProgress'))
        $s.AllTerminal | Should -BeFalse
        $s.AllSucceeded | Should -BeFalse
    }
    It 'lists failed reasons for terminal failures' {
        $s = Get-PreWipeStatus -Actions @((New-Action 'BiosPasswordRemoval' 'Failed' 'bad password'))
        $s.AllTerminal | Should -BeTrue
        $s.AllSucceeded | Should -BeFalse
        $s.FailedReasons | Should -Contain 'BiosPasswordRemoval: bad password'
    }
    It 'flags a passed deadline' {
        $s = Get-PreWipeStatus -Actions @((New-Action 'LicenseRemoval' 'InProgress')) `
            -DueAtUtc ([datetime]::UtcNow.AddHours(-1)) -NowUtc ([datetime]::UtcNow)
        $s.DeadlinePassed | Should -BeTrue
    }
    It 'does not flag a future deadline' {
        $s = Get-PreWipeStatus -Actions @((New-Action 'LicenseRemoval' 'InProgress')) `
            -DueAtUtc ([datetime]::UtcNow.AddHours(1)) -NowUtc ([datetime]::UtcNow)
        $s.DeadlinePassed | Should -BeFalse
    }
}

Describe 'Invoke-CloudDelete' {
    It 'skips Intune delete when no device id is present' {
        $r = Invoke-CloudDelete -Target 'Intune' -Context ([pscustomobject]@{ })
        $r.Status | Should -Be 'Skipped'
    }
    It 'fails for an unknown cloud target' {
        $r = Invoke-CloudDelete -Target 'ActiveDirectory' -Context ([pscustomobject]@{ })
        $r.Status | Should -Be 'Failed'
    }
}

Describe 'Get-ReconcileBackoffSeconds' {
    It 'grows exponentially from the base' {
        Get-ReconcileBackoffSeconds -RetryCount 0 -BaseSeconds 10 -MaxSeconds 3600 | Should -Be 10
        Get-ReconcileBackoffSeconds -RetryCount 1 -BaseSeconds 10 -MaxSeconds 3600 | Should -Be 20
        Get-ReconcileBackoffSeconds -RetryCount 3 -BaseSeconds 10 -MaxSeconds 3600 | Should -Be 80
    }
    It 'caps at the maximum' {
        Get-ReconcileBackoffSeconds -RetryCount 20 -BaseSeconds 10 -MaxSeconds 600 | Should -Be 600
    }
}

Describe 'Get-ReconcileActionDecision' {
    It 'marks success as terminal' {
        $d = Get-ReconcileActionDecision -Result ([pscustomobject]@{ Status = 'Success'; Detail = 'done'; Transient = $false }) -RetryCount 2
        $d.Terminal | Should -BeTrue
        $d.Status | Should -Be 'Success'
        $d.FinalOutcome | Should -Be 'Success'
        $d.BackoffSeconds | Should -BeNullOrEmpty
    }
    It 'marks a hard failure as terminal' {
        $d = Get-ReconcileActionDecision -Result ([pscustomobject]@{ Status = 'Failed'; Detail = 'nope'; Transient = $false }) -RetryCount 0
        $d.Terminal | Should -BeTrue
        $d.Status | Should -Be 'Failed'
    }
    It 'retries a transient failure with backoff below the cap' {
        $d = Get-ReconcileActionDecision -Result ([pscustomobject]@{ Status = 'Failed'; Detail = 'pending'; Transient = $true }) -RetryCount 1 -MaxRetries 10 -BackoffBaseSeconds 10 -BackoffMaxSeconds 3600
        $d.Terminal | Should -BeFalse
        $d.Status | Should -Be 'InProgress'
        $d.NewRetryCount | Should -Be 2
        $d.BackoffSeconds | Should -Be 40
    }
    It 'fails once max retries is reached' {
        $d = Get-ReconcileActionDecision -Result ([pscustomobject]@{ Status = 'Failed'; Detail = 'still pending'; Transient = $true }) -RetryCount 9 -MaxRetries 10
        $d.Terminal | Should -BeTrue
        $d.Status | Should -Be 'Failed'
        $d.Detail | Should -Match 'max retries'
    }
}

Describe 'Invoke-ProviderStatus dispatch' {
    It 'returns $null for on-prem targets (owned by the agent)' {
        Invoke-ProviderStatus -Target 'ActiveDirectory' -Context ([pscustomobject]@{ }) | Should -BeNullOrEmpty
        Invoke-ProviderStatus -Target 'ConfigMgr' -Context ([pscustomobject]@{ }) | Should -BeNullOrEmpty
        Invoke-ProviderStatus -Target 'LicenseRemoval' -Context ([pscustomobject]@{ }) | Should -BeNullOrEmpty
        Invoke-ProviderStatus -Target 'BiosPasswordRemoval' -Context ([pscustomobject]@{ }) | Should -BeNullOrEmpty
    }
    It 'reconciles Autopilot as terminal success' {
        $r = Invoke-ProviderStatus -Target 'Autopilot' -Context ([pscustomobject]@{ })
        $r.Status | Should -Be 'Success'
    }
}

Describe 'Get-OrchestrationOptions retry defaults' {
    It 'exposes retry base and max delay defaults' {
        $o = Get-OrchestrationOptions
        $o.RetryBaseDelaySeconds | Should -Be 10
        $o.RetryMaxDelaySeconds | Should -Be 3600
    }
}
