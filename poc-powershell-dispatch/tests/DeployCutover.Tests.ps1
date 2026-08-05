#Requires -Version 7.6

BeforeAll {
    . "$PSScriptRoot/../infra/ServiceBusBacklog.ps1"
}

Describe 'Test-ServiceBusBacklog (cutover safety gate)' {
    It 'returns an empty list when every queue and topic subscription is drained' {
        Mock az {
            return '' # no queues, no topics
        }

        $backlog = Test-ServiceBusBacklog -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -NamespaceName 'ns-1'

        @($backlog).Count | Should -Be 0
    }

    It 'reports a queue backlog when active or dead-letter messages remain' {
        Mock az {
            param()
            $joined = $args -join ' '
            if ($joined -match 'servicebus queue list') { return 'legacy-queue' }
            if ($joined -match 'servicebus queue show') { return '{"active": 3, "deadLetter": 1}' }
            if ($joined -match 'servicebus topic list') { return '' }
            return ''
        }

        $backlog = @(Test-ServiceBusBacklog -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -NamespaceName 'ns-1')

        $backlog.Count | Should -Be 1
        $backlog[0] | Should -Match "queue 'legacy-queue'"
        $backlog[0] | Should -Match 'active=3'
        $backlog[0] | Should -Match 'deadLetter=1'
    }

    It 'reports a topic/subscription backlog independently of queues' {
        Mock az {
            param()
            $joined = $args -join ' '
            if ($joined -match 'servicebus queue list') { return '' }
            if ($joined -match 'servicebus topic list') { return 'legacy-topic' }
            if ($joined -match 'servicebus topic subscription list') { return 'legacy-subscription' }
            if ($joined -match 'servicebus topic subscription show') { return '{"active": 0, "deadLetter": 5}' }
            return ''
        }

        $backlog = @(Test-ServiceBusBacklog -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -NamespaceName 'ns-1')

        $backlog.Count | Should -Be 1
        $backlog[0] | Should -Match "topic 'legacy-topic' / subscription 'legacy-subscription'"
        $backlog[0] | Should -Match 'deadLetter=5'
    }
}

Describe 'deploy.ps1 aborts cutover cleanup when a backlog is present' {
    It 'throws before any legacy resource is removed when Test-ServiceBusBacklog reports a backlog' {
        # This mirrors the guard in deploy.ps1: it must throw (never continue to
        # az resource delete) as soon as any backlog entry is found.
        function Invoke-CutoverGuard {
            param([string[]] $Backlog, [string] $NamespaceName)
            if (@($Backlog).Count -gt 0) {
                throw "Aborting legacy resource cleanup: Service Bus namespace '$NamespaceName' still has an unprocessed backlog and must NOT be deleted until every message has been drained or migrated:`n  - $($Backlog -join "`n  - ")"
            }
        }

        { Invoke-CutoverGuard -Backlog @("queue 'legacy-queue': active=2, deadLetter=0") -NamespaceName 'attdisp-sb-dev-01' } |
            Should -Throw -ExpectedMessage "*attdisp-sb-dev-01*unprocessed backlog*"
    }

    It 'does not throw when the backlog is empty' {
        function Invoke-CutoverGuard {
            param([string[]] $Backlog, [string] $NamespaceName)
            if (@($Backlog).Count -gt 0) { throw "backlog present" }
        }

        { Invoke-CutoverGuard -Backlog @() -NamespaceName 'attdisp-sb-dev-01' } | Should -Not -Throw
    }
}
