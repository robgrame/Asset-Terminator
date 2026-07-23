#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulesDir = Join-Path $PSScriptRoot '..' 'modules'
    if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $modulesDir) {
        $env:PSModulePath = $modulesDir + [IO.Path]::PathSeparator + $env:PSModulePath
    }
    Import-Module 'AT.Common' -Force
    Import-Module 'AT.Infrastructure' -Force
}

Describe 'AT.Infrastructure SQL state helpers' {
    It 'flags terminal states' {
        Test-IsTerminalState 'Completed' | Should -BeTrue
        Test-IsTerminalState 'Failed' | Should -BeTrue
        Test-IsTerminalState 'GuardrailsFailed' | Should -BeTrue
        Test-IsTerminalState 'TimedOut' | Should -BeTrue
    }
    It 'does not flag active states' {
        Test-IsTerminalState 'InProgress' | Should -BeFalse
        Test-IsTerminalState 'Requested' | Should -BeFalse
    }
}

Describe 'AT.Infrastructure Messaging routing' {
    It 'routes AD/SCCM/license/BIOS to on-prem' {
        foreach ($t in 'ActiveDirectory','ConfigMgr','LicenseRemoval','BiosPasswordRemoval') {
            Test-IsOnPremTarget $t | Should -BeTrue
        }
    }
    It 'routes cloud targets off on-prem' {
        foreach ($t in 'Intune','EntraId','Wipe','Autopilot','Retire') {
            Test-IsOnPremTarget $t | Should -BeFalse
        }
    }
}

Describe 'AT.Infrastructure Callback backoff' {
    It 'grows exponentially from the base delay' {
        Get-BackoffDelay -Attempt 1 -BaseSeconds 2 | Should -Be 2
        Get-BackoffDelay -Attempt 2 -BaseSeconds 2 | Should -Be 4
        Get-BackoffDelay -Attempt 3 -BaseSeconds 2 | Should -Be 8
    }
    It 'caps at MaxSeconds' {
        Get-BackoffDelay -Attempt 20 -BaseSeconds 2 -MaxSeconds 300 | Should -Be 300
    }
    It 'applies jitter within 50%-100% of the computed delay' {
        $d = Get-BackoffDelay -Attempt 3 -BaseSeconds 2 -Jitter -JitterFactor 0
        $d | Should -Be 4   # 8 * (0.5 + 0.5*0) = 4
        $d2 = Get-BackoffDelay -Attempt 3 -BaseSeconds 2 -Jitter -JitterFactor 1
        $d2 | Should -Be 8  # 8 * (0.5 + 0.5*1) = 8
    }
}

Describe 'AT.Infrastructure callback envelope' {
    It 'assigns a unique eventId per callback' {
        $c1 = New-ServiceNowCallback -RequestId 'R1' -OverallStatus 'Completed'
        $c2 = New-ServiceNowCallback -RequestId 'R1' -OverallStatus 'Completed'
        $c1.eventId | Should -Not -Be $c2.eventId
        { [guid]::Parse($c1.eventId) } | Should -Not -Throw
    }
}
