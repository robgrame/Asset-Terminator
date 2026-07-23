#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulesDir = Join-Path $PSScriptRoot '..' 'modules'
    if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $modulesDir) {
        $env:PSModulePath = $modulesDir + [IO.Path]::PathSeparator + $env:PSModulePath
    }
    Import-Module 'AT.Common' -Force
    Import-Module 'AT.Guardrails' -Force

    $script:Config = [pscustomobject]@{
        guardrails = @(
            [pscustomobject]@{ name = 'Encryption';    enabled = $true; mode = 'Mandatory'; overridable = $true;  settings = [pscustomobject]@{} },
            [pscustomobject]@{ name = 'Inactivity';    enabled = $true; mode = 'Warning';   settings = [pscustomobject]@{ minimumInactiveDays = 14 } },
            [pscustomobject]@{ name = 'CriticalGroup'; enabled = $true; mode = 'Mandatory'; overridable = $false; settings = [pscustomobject]@{ blockedGroups = @('Executives') } }
        )
    }
}

Describe 'AT.Guardrails engine' {
    It 'allows the wipe when all mandatory guardrails pass' {
        $device = [pscustomobject]@{ DeviceType = 'Windows'; isEncrypted = $true; lastSyncDateTime = ([datetime]::UtcNow).AddDays(-30).ToString('o'); deviceCategoryDisplayName = 'Standard' }
        $d = Invoke-Guardrails -Device $device -Config $script:Config
        $d.Allowed | Should -BeTrue
        $d.BlockingReasons.Count | Should -Be 0
    }

    It 'blocks the wipe when encryption (mandatory) fails' {
        $device = [pscustomobject]@{ DeviceType = 'Windows'; isEncrypted = $false; lastSyncDateTime = ([datetime]::UtcNow).AddDays(-30).ToString('o'); deviceCategoryDisplayName = 'Standard' }
        $d = Invoke-Guardrails -Device $device -Config $script:Config
        $d.Allowed | Should -BeFalse
        ($d.BlockingReasons -join ' ') | Should -Match 'Encryption'
    }

    It 'does not block on a warning-mode failure' {
        $device = [pscustomobject]@{ DeviceType = 'Windows'; isEncrypted = $true; lastSyncDateTime = ([datetime]::UtcNow).AddDays(-1).ToString('o'); deviceCategoryDisplayName = 'Standard' }
        $d = Invoke-Guardrails -Device $device -Config $script:Config
        $d.Allowed | Should -BeTrue
        ($d.Results | Where-Object Name -eq 'Inactivity').Passed | Should -BeFalse
    }

    It 'bypasses an overridable mandatory failure when overridden' {
        $device = [pscustomobject]@{ DeviceType = 'Windows'; isEncrypted = $false; lastSyncDateTime = ([datetime]::UtcNow).AddDays(-30).ToString('o'); deviceCategoryDisplayName = 'Standard' }
        $d = Invoke-Guardrails -Device $device -Config $script:Config -OverriddenGuardrails @('Encryption')
        $d.Allowed | Should -BeTrue
        $d.OverriddenReasons.Count | Should -Be 1
    }

    It 'does NOT bypass a non-overridable guardrail even if overridden' {
        $device = [pscustomobject]@{ DeviceType = 'Windows'; isEncrypted = $true; lastSyncDateTime = ([datetime]::UtcNow).AddDays(-30).ToString('o'); deviceCategoryDisplayName = 'Executives' }
        $d = Invoke-Guardrails -Device $device -Config $script:Config -OverriddenGuardrails @('CriticalGroup')
        $d.Allowed | Should -BeFalse
        ($d.BlockingReasons -join ' ') | Should -Match 'CriticalGroup'
    }

    It 'fails closed when a guardrail throws' {
        Register-Guardrail -Name 'Boom' -Function 'Test-BoomGuardrail'
        function global:Test-BoomGuardrail { param($Device, $Settings) throw 'kaboom' }
        $cfg = [pscustomobject]@{ guardrails = @([pscustomobject]@{ name = 'Boom'; enabled = $true; mode = 'Mandatory' }) }
        $device = [pscustomobject]@{ isEncrypted = $true }
        $d = Invoke-Guardrails -Device $device -Config $cfg
        $d.Allowed | Should -BeFalse
        ($d.BlockingReasons -join ' ') | Should -Match 'evaluation error'
        Remove-Item function:Test-BoomGuardrail -ErrorAction SilentlyContinue
    }

    It 'skips a disabled guardrail' {
        # Parity with GuardrailEngineTests.DisabledGuardrailIsSkipped.
        $cfg = [pscustomobject]@{ guardrails = @([pscustomobject]@{ name = 'Encryption'; enabled = $false; mode = 'Mandatory' }) }
        $device = [pscustomobject]@{ DeviceType = 'Windows'; isEncrypted = $false }
        $d = Invoke-Guardrails -Device $device -Config $cfg
        @($d.Results).Count | Should -Be 0
        $d.Allowed | Should -BeTrue
    }
}

Describe 'Encryption guardrail (parity with EncryptionGuardrail.cs)' {
    It 'passes an encrypted Windows device' {
        (Test-EncryptionGuardrail -Device ([pscustomobject]@{ DeviceType = 'Windows'; isEncrypted = $true; hasRecoveryKeyEscrowed = $false }) -Settings $null).Passed | Should -BeTrue
    }
    It 'passes an unencrypted Windows device with an escrowed recovery key' {
        (Test-EncryptionGuardrail -Device ([pscustomobject]@{ DeviceType = 'Windows'; isEncrypted = $false; hasRecoveryKeyEscrowed = $true }) -Settings $null).Passed | Should -BeTrue
    }
    It 'blocks an unencrypted Windows device without an escrowed recovery key' {
        (Test-EncryptionGuardrail -Device ([pscustomobject]@{ DeviceType = 'Windows'; isEncrypted = $false; hasRecoveryKeyEscrowed = $false }) -Settings $null).Passed | Should -BeFalse
    }
    It 'blocks a macOS device with FileVault off' {
        (Test-EncryptionGuardrail -Device ([pscustomobject]@{ DeviceType = 'MacOS'; isEncrypted = $false; hasRecoveryKeyEscrowed = $null }) -Settings $null).Passed | Should -BeFalse
    }
    It 'passes an iOS device (platform-enforced)' {
        (Test-EncryptionGuardrail -Device ([pscustomobject]@{ DeviceType = 'iOS'; isEncrypted = $null; hasRecoveryKeyEscrowed = $null }) -Settings $null).Passed | Should -BeTrue
    }
    It 'fails closed on unknown Windows encryption state' {
        $r = Test-EncryptionGuardrail -Device ([pscustomobject]@{ DeviceType = 'Windows'; isEncrypted = $null; hasRecoveryKeyEscrowed = $false }) -Settings $null
        $r.Passed | Should -BeFalse
        $r.Reason | Should -Match 'unknown'
    }
}

Describe 'Inactivity guardrail (parity with InactivityGuardrail.cs)' {
    BeforeAll { $script:InactivitySettings = [pscustomobject]@{ minimumInactiveDays = 30 } }
    It 'blocks a recently active device' {
        $r = Test-InactivityGuardrail -Device ([pscustomobject]@{ lastSyncDateTime = ([datetime]::UtcNow).AddDays(-10).ToString('o') }) -Settings $script:InactivitySettings
        $r.Passed | Should -BeFalse
        $r.Reason | Should -Match 'active too recently'
    }
    It 'passes a device inactive beyond the threshold' {
        (Test-InactivityGuardrail -Device ([pscustomobject]@{ lastSyncDateTime = ([datetime]::UtcNow).AddDays(-31).ToString('o') }) -Settings $script:InactivitySettings).Passed | Should -BeTrue
    }
    It 'fails closed on unknown last activity' {
        $r = Test-InactivityGuardrail -Device ([pscustomobject]@{ lastSyncDateTime = $null }) -Settings $script:InactivitySettings
        $r.Passed | Should -BeFalse
        $r.Reason | Should -Match 'unknown'
    }
}

Describe 'CriticalGroup guardrail (parity with CriticalGroupGuardrail.cs)' {
    BeforeAll { $script:GroupSettings = [pscustomobject]@{ BlockedGroups = 'Privileged Devices, Executive Devices' } }
    It 'blocks a device in a blocked group' {
        (Test-CriticalGroupGuardrail -Device ([pscustomobject]@{ groupMemberships = @('Standard', 'Privileged Devices') }) -Settings $script:GroupSettings).Passed | Should -BeFalse
    }
    It 'passes a device not in any blocked group' {
        (Test-CriticalGroupGuardrail -Device ([pscustomobject]@{ groupMemberships = @('Standard') }) -Settings $script:GroupSettings).Passed | Should -BeTrue
    }
}
