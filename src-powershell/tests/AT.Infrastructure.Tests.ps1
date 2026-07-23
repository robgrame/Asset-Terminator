#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulesDir = Join-Path $PSScriptRoot '..' 'modules'
    if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $modulesDir) {
        $env:PSModulePath = $modulesDir + [IO.Path]::PathSeparator + $env:PSModulePath
    }
    Import-Module 'AT.Common' -Force
    Import-Module 'AT.Infrastructure' -Force
}

Describe 'AT.Infrastructure.Sla' {
    It 'computes the due date from MaxCompletionHours' {
        $created = [datetime]'2026-01-01T00:00:00Z'
        (Get-SlaDueAt -Category 'Standard' -CreatedAtUtc $created).ToUniversalTime() |
            Should -Be ([datetime]'2026-01-08T00:00:00Z').ToUniversalTime()
    }
    It 'returns WithinSla well before the deadline' {
        $created = [datetime]::UtcNow
        Get-SlaState -Category 'Standard' -CreatedAtUtc $created -NowUtc $created.AddHours(1) | Should -Be 'WithinSla'
    }
    It 'returns AtRisk past the at-risk threshold' {
        $created = [datetime]'2026-01-01T00:00:00Z'
        # Standard: 168h, threshold 0.8 => 134.4h
        Get-SlaState -Category 'Standard' -CreatedAtUtc $created -NowUtc $created.AddHours(140) | Should -Be 'AtRisk'
    }
    It 'returns Breached at or past the deadline' {
        $created = [datetime]'2026-01-01T00:00:00Z'
        Get-SlaState -Category 'Standard' -CreatedAtUtc $created -NowUtc $created.AddHours(168) | Should -Be 'Breached'
    }
    It 'uses tighter Critical deadlines' {
        $created = [datetime]'2026-01-01T00:00:00Z'
        Get-SlaState -Category 'Critical' -CreatedAtUtc $created -NowUtc $created.AddHours(25) | Should -Be 'Breached'
    }
}

Describe 'AT.Infrastructure.Audit hash chain' {
    It 'produces a stable uppercase-hex SHA-256' {
        $rec = New-AuditRecord -RequestId 'R1' -Action 'RequestReceived' -Outcome 'Accepted'
        $h1 = Get-AuditHash -Record $rec -PreviousHash $null
        $h2 = Get-AuditHash -Record $rec -PreviousHash $null
        $h1 | Should -Be $h2
        $h1 | Should -Match '^[0-9A-F]{64}$'
    }
    It 'changes the hash when the previous hash changes' {
        $rec = New-AuditRecord -RequestId 'R1' -Action 'A' -Outcome 'ok'
        (Get-AuditHash -Record $rec -PreviousHash 'AAAA') | Should -Not -Be (Get-AuditHash -Record $rec -PreviousHash 'BBBB')
    }
    It 'validates a correctly chained sequence' {
        $records = @()
        $prev = $null
        foreach ($a in 'Received','Guardrails','Wipe') {
            $r = New-AuditRecord -RequestId 'R1' -Action $a -Outcome 'ok'
            $r.previousHash = $prev
            $r.hash = Get-AuditHash -Record $r -PreviousHash $prev
            $prev = $r.hash
            $records += $r
        }
        (Test-AuditChain -Records $records).Valid | Should -BeTrue
    }
    It 'detects a tampered record' {
        $records = @()
        $prev = $null
        foreach ($a in 'Received','Wipe') {
            $r = New-AuditRecord -RequestId 'R1' -Action $a -Outcome 'ok'
            $r.previousHash = $prev
            $r.hash = Get-AuditHash -Record $r -PreviousHash $prev
            $prev = $r.hash
            $records += $r
        }
        $records[1].outcome = 'tampered'
        $result = Test-AuditChain -Records $records
        $result.Valid | Should -BeFalse
        $result.BrokenAt | Should -Be 1
    }
    It 'sanitizes blob prefixes' {
        ConvertTo-BlobPrefix 'SNOW/INC:001' | Should -Be 'SNOW_INC_001'
    }
}

Describe 'AT.Infrastructure.SqlStateStore idempotency' {
    # Parity with IntakeServiceTests.ValidNewRequest_StartsWorkflowOnce and
    # DuplicateRequest_IsIdempotentAndDoesNotRestartWorkflow: New-DecommissionRequestRow
    # is the GetOrCreateAsync equivalent — it returns Created=$true only for a brand-new
    # request (so the caller enqueues the workflow exactly once) and Created=$false for a
    # replay (so no second workflow is started). The SqlClient layer is faked here, the
    # same way the .NET test swaps in an in-memory IStateStore.
    BeforeAll {
        # A self-contained fake SqlConnection: BeginTransaction/CreateCommand/Dispose all
        # build their return values inline so the ScriptMethod bodies never depend on
        # helper functions that live outside the module session state.
        function New-FakeConnection {
            $state = @{ Committed = $false; RolledBack = $false }
            $tx = [pscustomobject]@{}
            $tx | Add-Member -MemberType ScriptMethod -Name Commit -Value ({ $state.Committed = $true }.GetNewClosure()) -Force
            $tx | Add-Member -MemberType ScriptMethod -Name Rollback -Value ({ $state.RolledBack = $true }.GetNewClosure()) -Force
            $conn = [pscustomobject]@{ State = $state }
            $conn | Add-Member -MemberType ScriptMethod -Name BeginTransaction -Value ({ $tx }.GetNewClosure()) -Force
            $conn | Add-Member -MemberType ScriptMethod -Name CreateCommand -Value {
                $params = [pscustomobject]@{}
                $params | Add-Member -MemberType ScriptMethod -Name AddWithValue -Value { param($n, $v) } -Force
                $c = [pscustomobject]@{ Transaction = $null; CommandText = $null; Parameters = $params }
                $c | Add-Member -MemberType ScriptMethod -Name ExecuteNonQuery -Value { 1 } -Force
                $c
            } -Force
            $conn | Add-Member -MemberType ScriptMethod -Name Dispose -Value { } -Force
            $conn
        }
        function New-SampleRecord {
            [pscustomobject]@{
                requestId = 'REQ-1'; correlationId = 'COR-1'; assetId = 'AST-1'; deviceName = 'PC-1'
                serialNumber = 'SN-1'; primaryUserUpn = 'user@contoso.com'; deviceType = 'Windows'
                assetCategory = 'Standard'; dispositionType = 'Terminate'; ticketNumber = 'INC-1'
                requestor = 'servicenow'; dryRun = $false; state = 'Received'; slaState = 'WithinSla'
                createdAtUtc = [datetime]::UtcNow; lastUpdatedAtUtc = [datetime]::UtcNow
                dueAtUtc = [datetime]::UtcNow.AddDays(7); requestJson = '{}'
                actions = @([pscustomobject]@{ target = 'IntuneWipe'; action = 'Wipe'; status = 'Pending' })
            }
        }
    }

    It 'creates a new request once and reports Created=$true' {
        InModuleScope 'SqlStateStore' -Parameters @{ Conn = (New-FakeConnection); Sample = (New-SampleRecord) } {
            param($Conn, $Sample)
            Mock New-SqlConnection { $Conn }
            Mock Get-DecommissionRequest { $null }

            $result = New-DecommissionRequestRow -Record $Sample

            $result.Created | Should -BeTrue
            $result.Record.requestId | Should -Be 'REQ-1'
        }
    }

    It 'is idempotent for a duplicate request and reports Created=$false' {
        InModuleScope 'SqlStateStore' -Parameters @{ Conn = (New-FakeConnection); Sample = (New-SampleRecord) } {
            param($Conn, $Sample)
            Mock New-SqlConnection { $Conn }
            Mock Get-DecommissionRequest {
                [pscustomobject]@{ requestId = 'REQ-1'; state = 'InProgress'; actions = @() }
            }

            $result = New-DecommissionRequestRow -Record $Sample

            $result.Created | Should -BeFalse
            $result.Record.state | Should -Be 'InProgress'
        }
    }
}
