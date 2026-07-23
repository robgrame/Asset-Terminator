#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulesDir = Join-Path $PSScriptRoot '..' 'modules'
    $apiModulesDir = Join-Path $PSScriptRoot '..' 'api' 'Modules'
    foreach ($dir in @($modulesDir, $apiModulesDir)) {
        if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $dir) {
            $env:PSModulePath = $dir + [IO.Path]::PathSeparator + $env:PSModulePath
        }
    }
    Import-Module 'AT.Common' -Force
    Import-Module 'AT.Core' -Force
    Import-Module 'AT.Api.Auth' -Force
    Import-Module 'AT.Api.Support' -Force
}

Describe 'AT.Api.Auth IP allowlist' {
    It 'allows any IP when the allowlist is empty' {
        Test-IpAllowed -RemoteIp '8.8.8.8' -Allowlist @() | Should -BeTrue
    }
    It 'matches an exact IP' {
        Test-IpAllowed -RemoteIp '203.0.113.5' -Allowlist @('203.0.113.5') | Should -BeTrue
    }
    It 'rejects an IP outside the allowlist' {
        Test-IpAllowed -RemoteIp '198.51.100.7' -Allowlist @('203.0.113.5') | Should -BeFalse
    }
    It 'matches an IP inside a CIDR range' {
        Test-IpAllowed -RemoteIp '203.0.113.42' -Allowlist @('203.0.113.0/24') | Should -BeTrue
    }
    It 'rejects an IP outside a CIDR range' {
        Test-IpAllowed -RemoteIp '203.0.114.1' -Allowlist @('203.0.113.0/24') | Should -BeFalse
    }
    It 'rejects a null/blank IP when an allowlist is configured' {
        Test-IpAllowed -RemoteIp '' -Allowlist @('203.0.113.0/24') | Should -BeFalse
    }
}

Describe 'AT.Api.Auth API key gate' {
    It 'denies with 401 when no keys are configured (fail-closed)' {
        $req = [pscustomobject]@{ Headers = @{ 'X-Forwarded-For' = '203.0.113.5'; 'x-api-key' = 'anything' } }
        $cfg = [pscustomobject]@{ apiKeyHeader = 'x-api-key'; apiKeys = @(); ipAllowlist = @() }
        (Test-HttpAuthGate -Request $req -Config $cfg).StatusCode | Should -Be 401
    }
    It 'denies with 403 when the source IP is not allowed' {
        $req = [pscustomobject]@{ Headers = @{ 'X-Forwarded-For' = '198.51.100.9'; 'x-api-key' = 'k1' } }
        $cfg = [pscustomobject]@{ apiKeyHeader = 'x-api-key'; apiKeys = @('k1'); ipAllowlist = @('203.0.113.0/24') }
        (Test-HttpAuthGate -Request $req -Config $cfg).StatusCode | Should -Be 403
    }
    It 'denies with 401 when the key is missing' {
        $req = [pscustomobject]@{ Headers = @{ 'X-Forwarded-For' = '203.0.113.5' } }
        $cfg = [pscustomobject]@{ apiKeyHeader = 'x-api-key'; apiKeys = @('k1'); ipAllowlist = @() }
        (Test-HttpAuthGate -Request $req -Config $cfg).StatusCode | Should -Be 401
    }
    It 'allows (returns $null) when IP and key are valid' {
        $req = [pscustomobject]@{ Headers = @{ 'X-Forwarded-For' = '203.0.113.5'; 'x-api-key' = 'k1' } }
        $cfg = [pscustomobject]@{ apiKeyHeader = 'x-api-key'; apiKeys = @('k1'); ipAllowlist = @('203.0.113.0/24') }
        Test-HttpAuthGate -Request $req -Config $cfg | Should -BeNullOrEmpty
    }
    It 'strips the port from an X-Forwarded-For entry' {
        Get-RemoteIp -Headers @{ 'X-Forwarded-For' = '203.0.113.5:44321, 10.0.0.1' } | Should -Be '203.0.113.5'
    }
}

Describe 'AT.Api.Auth caller RBAC' {
    BeforeAll {
        $script:MakePrincipal = {
            param([string[]] $Roles, [string] $Upn)
            $claims = @()
            if ($Upn) { $claims += @{ typ = 'preferred_username'; val = $Upn } }
            foreach ($r in $Roles) { $claims += @{ typ = 'roles'; val = $r } }
            $json = (@{ claims = $claims } | ConvertTo-Json -Depth 6)
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        }
    }
    It 'extracts roles from the Easy Auth client principal' {
        $req = [pscustomobject]@{ Headers = @{ 'x-ms-client-principal' = (& $script:MakePrincipal -Roles @('Approver') -Upn 'a@x.com') } }
        Test-CallerInRole -Request $req -Role 'Approver' | Should -BeTrue
        Test-CallerInRole -Request $req -Role 'Admin' | Should -BeFalse
    }
    It 'extracts the caller UPN' {
        $req = [pscustomobject]@{ Headers = @{ 'x-ms-client-principal' = (& $script:MakePrincipal -Roles @() -Upn 'b@x.com') } }
        Get-CallerUpn -Request $req | Should -Be 'b@x.com'
    }
    It 'honors the x-debug-roles fallback when no principal is present' {
        $req = [pscustomobject]@{ Headers = @{ 'x-debug-roles' = 'Approver, Auditor' } }
        Test-CallerInRole -Request $req -Role 'Auditor' | Should -BeTrue
    }
    It 'returns unknown UPN when nothing is supplied' {
        Get-CallerUpn -Request ([pscustomobject]@{ Headers = @{} }) | Should -Be 'unknown'
    }
}

Describe 'AT.Api.Support config binding' {
    AfterEach {
        Get-ChildItem env: | Where-Object Name -like 'AssetTerminator__*' | ForEach-Object { Remove-Item "env:$($_.Name)" -ErrorAction SilentlyContinue }
    }
    It 'reads an indexed config list' {
        $env:AssetTerminator__Ingestion__ApiKeys__0 = 'k1'
        $env:AssetTerminator__Ingestion__ApiKeys__1 = 'k2'
        (Get-IngestionOptions).apiKeys | Should -Be @('k1', 'k2')
    }
    It 'reads a semicolon-separated config list' {
        $env:AssetTerminator__Ingestion__IpAllowlist = '203.0.113.0/24; 198.51.100.1'
        (Get-IngestionOptions).ipAllowlist | Should -Be @('203.0.113.0/24', '198.51.100.1')
    }
    It 'defaults PreWipe flags to true' {
        $p = Get-PreWipeOptions
        $p.DeleteFromAutopilot | Should -BeTrue
        $p.RemoveBiosPassword | Should -BeTrue
    }
    It 'applies default override quorum per category' {
        Get-OverrideRequiredFor -AssetCategory 'Standard' | Should -Be 1
        Get-OverrideRequiredFor -AssetCategory 'Vip' | Should -Be 2
        Get-OverrideRequiredFor -AssetCategory 'Critical' | Should -Be 2
    }
}

Describe 'AT.Api.Support response mapping' {
    It 'maps a SQL record + actions to the status contract' {
        $record = [pscustomobject]@{
            RequestId = 'r1'; CorrelationId = 'c1'; TicketNumber = 'INC1'; State = 'InProgress'; SlaState = 'WithinSla'
            CreatedAtUtc = '2024-01-01T00:00:00Z'; LastUpdatedAtUtc = '2024-01-02T00:00:00Z'; DueAtUtc = '2024-01-08T00:00:00Z'
            actions = @(
                [pscustomobject]@{ Target = 'Wipe'; Action = 'Wipe'; Status = 'Pending'; Attempts = 0; FinalOutcome = $null; LastUpdatedUtc = $null }
            )
        }
        $status = ConvertTo-StatusResponse -Record $record
        $status.requestId | Should -Be 'r1'
        $status.overallStatus | Should -Be 'InProgress'
        $status.actions[0].target | Should -Be 'Wipe'
        $status.actions[0].retryCount | Should -Be 0
    }
    It 'maps an audit record to a history event' {
        $audit = [pscustomobject]@{ timestampUtc = '2024-01-01T00:00:00Z'; action = 'RequestReceived'; targetEnvironment = $null; outcome = 'Accepted'; actor = 'servicenow'; reason = 'dry-run' }
        $ev = ConvertTo-HistoryEvent -Audit $audit
        $ev.eventType | Should -Be 'RequestReceived'
        $ev.outcome | Should -Be 'Accepted'
    }
}
