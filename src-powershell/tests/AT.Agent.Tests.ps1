#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulesDir = Join-Path $PSScriptRoot '..' 'modules'
    $agentModules = Join-Path $PSScriptRoot '..' 'onprem-agent' 'Modules'
    foreach ($dir in @($modulesDir, $agentModules)) {
        if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $dir) {
            $env:PSModulePath = $dir + [IO.Path]::PathSeparator + $env:PSModulePath
        }
    }
    Import-Module 'AT.Common' -Force
    Import-Module 'AT.Core' -Force
    Import-Module 'AT.Infrastructure' -Force
    Import-Module 'AT.Providers.ActiveDirectory' -Force
    Import-Module 'AT.Providers.ConfigMgr' -Force
    Import-Module 'AT.Providers.DeviceActions' -Force
    Import-Module 'AT.Agent' -Force
    Import-Module 'AT.ServiceBusReceiver' -Force
}

Describe 'ConvertFrom-ActionDispatchMessage' {
    It 'parses a valid message' {
        $m = ConvertFrom-ActionDispatchMessage -Json '{"requestId":"r1","target":"ActiveDirectory"}'
        $m.RequestId | Should -Be 'r1'
        $m.Target | Should -Be 'ActiveDirectory'
    }

    It 'throws on empty body' {
        { ConvertFrom-ActionDispatchMessage -Json '' } | Should -Throw '*EmptyMessage*'
    }

    It 'throws on malformed JSON' {
        { ConvertFrom-ActionDispatchMessage -Json '{not json' } | Should -Throw '*MalformedJson*'
    }

    It 'throws when requestId is missing' {
        { ConvertFrom-ActionDispatchMessage -Json '{"target":"ConfigMgr"}' } | Should -Throw '*missing requestId*'
    }
}

Describe 'Get-AgentActionUpdate (ApplyResult parity)' {
    It 'maps success and skipped to final outcomes' {
        (Get-AgentActionUpdate -Result ([pscustomobject]@{ Status = 'Success' })).Status | Should -Be 'Success'
        (Get-AgentActionUpdate -Result ([pscustomobject]@{ Status = 'Skipped' })).FinalOutcome | Should -Be 'Skipped'
    }

    It 'reverts transient failures to InProgress with no final outcome' {
        $u = Get-AgentActionUpdate -Result ([pscustomobject]@{ Status = 'Failed'; Transient = $true })
        $u.Status | Should -Be 'InProgress'
        $u.FinalOutcome | Should -BeNullOrEmpty
    }

    It 'keeps hard failures final' {
        $u = Get-AgentActionUpdate -Result ([pscustomobject]@{ Status = 'Failed'; Transient = $false })
        $u.Status | Should -Be 'Failed'
        $u.FinalOutcome | Should -Be 'Failed'
    }
}

Describe 'Get-AgentDeviceContext' {
    It 'prefers the stored device-context JSON' {
        $rec = [pscustomobject]@{ RequestId = 'r1'; DeviceContextJson = '{"DeviceName":"STORED"}' }
        (Get-AgentDeviceContext -Record $rec).DeviceName | Should -Be 'STORED'
    }

    It 'falls back to building from the record when no JSON' {
        Mock -ModuleName 'AT.Agent' New-DeviceContext { [pscustomobject]@{ DeviceName = 'FROM-RECORD' } }
        $rec = [pscustomobject]@{ RequestId = 'r1'; DeviceContextJson = $null; DeviceName = 'FROM-RECORD' }
        (Get-AgentDeviceContext -Record $rec).DeviceName | Should -Be 'FROM-RECORD'
    }
}

Describe 'Invoke-AgentProvider dispatch' {
    It 'routes ActiveDirectory to Remove-AdComputer' {
        Mock -ModuleName 'AT.Agent' Remove-AdComputer { [pscustomobject]@{ Status = 'Success'; Detail = 'ad' } }
        $r = Invoke-AgentProvider -Target 'ActiveDirectory' -Context ([pscustomobject]@{ }) -Config ([pscustomobject]@{ DryRun = $true })
        $r.Detail | Should -Be 'ad'
        Should -Invoke -ModuleName 'AT.Agent' Remove-AdComputer -Times 1
    }

    It 'routes LicenseRemoval to Invoke-LicenseRemoval' {
        Mock -ModuleName 'AT.Agent' Invoke-LicenseRemoval { [pscustomobject]@{ Status = 'Skipped'; Detail = 'lic' } }
        $r = Invoke-AgentProvider -Target 'LicenseRemoval' -Context ([pscustomobject]@{ }) -Config ([pscustomobject]@{ DeviceActions = @{} })
        $r.Detail | Should -Be 'lic'
    }

    It 'fails ConfigMgr when the AdminService base URL is missing' {
        $r = Invoke-AgentProvider -Target 'ConfigMgr' -Context ([pscustomobject]@{ }) -Config ([pscustomobject]@{ SccmBaseUrl = '' })
        $r.Status | Should -Be 'Failed'
        $r.Transient | Should -BeTrue
    }

    It 'returns null for an unknown target' {
        Invoke-AgentProvider -Target 'Nope' -Context ([pscustomobject]@{ }) -Config ([pscustomobject]@{ }) | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-OnPremAction end-to-end' {
    BeforeEach {
        Mock -ModuleName 'AT.Agent' Add-AgentAudit { }
        Mock -ModuleName 'AT.Agent' Set-ActionStatus { }
    }

    It 'ignores unknown (non-on-prem) targets' {
        $r = Invoke-OnPremAction -Message ([pscustomobject]@{ RequestId = 'r1'; Target = 'Intune' }) -Config ([pscustomobject]@{ })
        $r.Handled | Should -BeFalse
    }

    It 'ignores when the request is not found' {
        Mock -ModuleName 'AT.Agent' Get-DecommissionRequest { $null }
        $r = Invoke-OnPremAction -Message ([pscustomobject]@{ RequestId = 'r1'; Target = 'ActiveDirectory' }) -Config ([pscustomobject]@{ })
        $r.Handled | Should -BeFalse
        $r.Detail | Should -Be 'request not found'
    }

    It 'ignores when the sub-action is absent on the record' {
        Mock -ModuleName 'AT.Agent' Get-DecommissionRequest {
            [pscustomobject]@{ RequestId = 'r1'; actions = @([pscustomobject]@{ Target = 'ConfigMgr' }) }
        }
        $r = Invoke-OnPremAction -Message ([pscustomobject]@{ RequestId = 'r1'; Target = 'ActiveDirectory' }) -Config ([pscustomobject]@{ })
        $r.Handled | Should -BeFalse
        $r.Detail | Should -Be 'sub-action not found'
    }

    It 'runs the provider, persists status and writes before/after audit' {
        Mock -ModuleName 'AT.Agent' Get-DecommissionRequest {
            [pscustomobject]@{ RequestId = 'r1'; DeviceContextJson = '{"DeviceName":"PC01"}'; actions = @([pscustomobject]@{ Target = 'ActiveDirectory' }) }
        }
        Mock -ModuleName 'AT.Agent' Invoke-AgentProvider { [pscustomobject]@{ Status = 'Success'; Detail = 'deleted CN=PC01'; Transient = $false } }

        $r = Invoke-OnPremAction -Message ([pscustomobject]@{ RequestId = 'r1'; Target = 'ActiveDirectory' }) -Config ([pscustomobject]@{ DryRun = $false })

        $r.Handled | Should -BeTrue
        $r.Status | Should -Be 'Success'
        Should -Invoke -ModuleName 'AT.Agent' Add-AgentAudit -Times 2
        Should -Invoke -ModuleName 'AT.Agent' Set-ActionStatus -Times 1 -ParameterFilter { $Status -eq 'Success' -and $FinalOutcome -eq 'Success' }
    }

    It 'persists a transient failure as InProgress' {
        Mock -ModuleName 'AT.Agent' Get-DecommissionRequest {
            [pscustomobject]@{ RequestId = 'r1'; actions = @([pscustomobject]@{ Target = 'ConfigMgr' }) }
        }
        Mock -ModuleName 'AT.Agent' New-DeviceContext { [pscustomobject]@{ DeviceName = 'PC01' } }
        Mock -ModuleName 'AT.Agent' Invoke-AgentProvider { [pscustomobject]@{ Status = 'Failed'; Detail = 'timeout'; Transient = $true } }

        $r = Invoke-OnPremAction -Message ([pscustomobject]@{ RequestId = 'r1'; Target = 'ConfigMgr' }) -Config ([pscustomobject]@{ })

        $r.Status | Should -Be 'InProgress'
        Should -Invoke -ModuleName 'AT.Agent' Set-ActionStatus -Times 1 -ParameterFilter { $Status -eq 'InProgress' }
    }
}

Describe 'ServiceBus receiver helpers' {
    It 'parses BrokerProperties JSON' {
        $bp = ConvertFrom-BrokerProperties -Json '{"SequenceNumber":12,"LockToken":"abc","MessageId":"r1:AD"}'
        $bp.SequenceNumber | Should -Be '12'
        $bp.LockToken | Should -Be 'abc'
    }

    It 'returns null on empty BrokerProperties' {
        ConvertFrom-BrokerProperties -Json '' | Should -BeNullOrEmpty
    }

    It 'prefers the server Location for the lock URI' {
        $msg = [pscustomobject]@{ LockLocation = 'https://ns/q/messages/1/tok'; SequenceNumber = '1'; LockToken = 'tok' }
        Resolve-LockUri -Message $msg -Namespace 'ns' -Queue 'q' | Should -Be 'https://ns/q/messages/1/tok'
    }

    It 'builds the lock URI from sequence + token when no Location' {
        $msg = [pscustomobject]@{ LockLocation = ''; SequenceNumber = '5'; LockToken = 'tok' }
        Resolve-LockUri -Message $msg -Namespace 'ns' -Queue 'q' | Should -Be 'https://ns/q/messages/5/tok'
    }

    It 'throws when the lock cannot be resolved' {
        $msg = [pscustomobject]@{ LockLocation = ''; SequenceNumber = ''; LockToken = '' }
        { Resolve-LockUri -Message $msg -Namespace 'ns' -Queue 'q' } | Should -Throw
    }
}
