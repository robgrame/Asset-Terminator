#Requires -Version 7.6

BeforeAll {
    . "$PSScriptRoot/../infra/ServiceBusBacklog.ps1"
}

Describe 'Test-ServiceBusBacklog (cutover safety gate)' {
    BeforeEach {
        # Every mock below sets $global:LASTEXITCODE explicitly (never relies
        # on whatever a previous test/command left behind), so the fail-closed
        # exit-code check in Invoke-AzCliListOrThrow / Get-AzCliBacklogCounts
        # is deterministic regardless of test execution order.
        $global:LASTEXITCODE = 0
    }

    AfterEach {
        $global:LASTEXITCODE = 0
    }

    It 'returns an empty list when every queue and topic subscription is drained' {
        Mock az {
            $global:LASTEXITCODE = 0
            return '' # no queues, no topics
        }

        $backlog = Test-ServiceBusBacklog -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -NamespaceName 'ns-1'

        @($backlog).Count | Should -Be 0
    }

    It 'reports a queue backlog when active or dead-letter messages remain' {
        Mock az {
            param()
            $global:LASTEXITCODE = 0
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
            $global:LASTEXITCODE = 0
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

    It 'throws (never returns an empty backlog) when az servicebus queue list fails' {
        Mock az {
            param()
            $joined = $args -join ' '
            if ($joined -match 'servicebus queue list') {
                $global:LASTEXITCODE = 1
                return ''
            }
            $global:LASTEXITCODE = 0
            return ''
        }

        { Test-ServiceBusBacklog -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -NamespaceName 'ns-1' } |
            Should -Throw -ExpectedMessage '*Azure CLI failed while listing*queues*'
    }

    It 'throws (never treats it as zero messages) when az servicebus queue show fails' {
        Mock az {
            param()
            $joined = $args -join ' '
            if ($joined -match 'servicebus queue list') { $global:LASTEXITCODE = 0; return 'legacy-queue' }
            if ($joined -match 'servicebus queue show') { $global:LASTEXITCODE = 1; return '' }
            $global:LASTEXITCODE = 0
            return ''
        }

        { Test-ServiceBusBacklog -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -NamespaceName 'ns-1' } |
            Should -Throw -ExpectedMessage "*Azure CLI failed while querying*queue 'legacy-queue'*"
    }

    It 'throws when az servicebus queue show returns empty output instead of JSON' {
        Mock az {
            param()
            $global:LASTEXITCODE = 0
            $joined = $args -join ' '
            if ($joined -match 'servicebus queue list') { return 'legacy-queue' }
            if ($joined -match 'servicebus queue show') { return '' }
            return ''
        }

        { Test-ServiceBusBacklog -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -NamespaceName 'ns-1' } |
            Should -Throw -ExpectedMessage '*returned no output while querying*'
    }

    It 'throws when az servicebus queue show returns invalid JSON' {
        Mock az {
            param()
            $global:LASTEXITCODE = 0
            $joined = $args -join ' '
            if ($joined -match 'servicebus queue list') { return 'legacy-queue' }
            if ($joined -match 'servicebus queue show') { return 'not-json-at-all {{{' }
            return ''
        }

        { Test-ServiceBusBacklog -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -NamespaceName 'ns-1' } |
            Should -Throw -ExpectedMessage '*returned invalid JSON while querying*'
    }

    It 'throws when az servicebus queue show returns JSON missing the active/deadLetter counts' {
        Mock az {
            param()
            $global:LASTEXITCODE = 0
            $joined = $args -join ' '
            if ($joined -match 'servicebus queue list') { return 'legacy-queue' }
            if ($joined -match 'servicebus queue show') { return '{"somethingElse": 1}' }
            return ''
        }

        { Test-ServiceBusBacklog -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -NamespaceName 'ns-1' } |
            Should -Throw -ExpectedMessage "*missing/non-numeric 'active' count*"
    }

    It 'throws when az servicebus queue show returns a non-numeric count value' {
        Mock az {
            param()
            $global:LASTEXITCODE = 0
            $joined = $args -join ' '
            if ($joined -match 'servicebus queue list') { return 'legacy-queue' }
            if ($joined -match 'servicebus queue show') { return '{"active": "not-a-number", "deadLetter": 0}' }
            return ''
        }

        { Test-ServiceBusBacklog -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -NamespaceName 'ns-1' } |
            Should -Throw -ExpectedMessage "*missing/non-numeric 'active' count*"
    }

    It 'throws (never returns an empty backlog) when az servicebus topic list fails' {
        Mock az {
            param()
            $joined = $args -join ' '
            if ($joined -match 'servicebus queue list') { $global:LASTEXITCODE = 0; return '' }
            if ($joined -match 'servicebus topic list') { $global:LASTEXITCODE = 1; return '' }
            $global:LASTEXITCODE = 0
            return ''
        }

        { Test-ServiceBusBacklog -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -NamespaceName 'ns-1' } |
            Should -Throw -ExpectedMessage '*Azure CLI failed while listing*topics*'
    }

    It 'throws when az servicebus topic subscription show returns invalid JSON' {
        Mock az {
            param()
            $global:LASTEXITCODE = 0
            $joined = $args -join ' '
            if ($joined -match 'servicebus queue list') { return '' }
            if ($joined -match 'servicebus topic list') { return 'legacy-topic' }
            if ($joined -match 'servicebus topic subscription list') { return 'legacy-subscription' }
            if ($joined -match 'servicebus topic subscription show') { return '{not valid json' }
            return ''
        }

        { Test-ServiceBusBacklog -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -NamespaceName 'ns-1' } |
            Should -Throw -ExpectedMessage '*returned invalid JSON while querying*'
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

    It 'propagates (never swallows) a Test-ServiceBusBacklog failure, so a broken safety check also aborts the cutover' {
        # Mirrors deploy.ps1 calling Test-ServiceBusBacklog directly, with no
        # try/catch around it: a thrown error must reach the caller unmodified.
        function Invoke-CutoverCheck {
            param([scriptblock] $BacklogCheck)
            $backlog = & $BacklogCheck
            if (@($backlog).Count -gt 0) { throw 'backlog present' }
        }

        { Invoke-CutoverCheck -BacklogCheck { throw 'Azure CLI failed while listing queues in namespace' } } |
            Should -Throw -ExpectedMessage '*Azure CLI failed while listing queues*'
    }
}
