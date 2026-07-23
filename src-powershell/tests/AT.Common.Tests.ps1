#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'modules' 'AT.Common' 'AT.Common.psd1'
    Import-Module $modulePath -Force
}

Describe 'AT.Common' {

    Context 'New-CorrelationId' {
        It 'returns a parseable GUID string' {
            $id = New-CorrelationId
            { [guid]::Parse($id) } | Should -Not -Throw
        }
        It 'returns a unique value each call' {
            (New-CorrelationId) | Should -Not -Be (New-CorrelationId)
        }
    }

    Context 'Get-HttpStatus' {
        It 'returns 0 when no HTTP response is present' {
            $err = $null
            try { throw 'plain error' } catch { $err = $_ }
            Get-HttpStatus $err | Should -Be 0
        }
    }

    Context 'Invoke-AtRetry' {
        It 'returns the script block output on success without retrying' {
            $script:calls = 0
            $result = Invoke-AtRetry -ScriptBlock { $script:calls++; 'ok' }
            $result | Should -Be 'ok'
            $script:calls | Should -Be 1
        }

        It 'retries on a transient predicate then succeeds' {
            $script:attempts = 0
            $result = Invoke-AtRetry -MaxRetries 3 -MaxDelaySeconds 0.01 -Predicate { $true } -ScriptBlock {
                $script:attempts++
                if ($script:attempts -lt 3) { throw 'transient' }
                'done'
            }
            $result | Should -Be 'done'
            $script:attempts | Should -Be 3
        }

        It 'does not retry when the predicate returns false' {
            $script:attempts = 0
            { Invoke-AtRetry -MaxRetries 5 -Predicate { $false } -ScriptBlock { $script:attempts++; throw 'fatal' } } |
                Should -Throw
            $script:attempts | Should -Be 1
        }

        It 'gives up after MaxRetries and rethrows' {
            $script:attempts = 0
            { Invoke-AtRetry -MaxRetries 2 -MaxDelaySeconds 0.01 -Predicate { $true } -ScriptBlock { $script:attempts++; throw 'always' } } |
                Should -Throw
            # 1 initial + 2 retries = 3 attempts
            $script:attempts | Should -Be 3
        }
    }

    Context 'Write-AtLog' {
        It 'emits a JSON line with the message and level' {
            $out = Write-AtLog -Message 'hello' -Level 'Information' -Properties @{ correlationId = 'abc' } 6>&1
            $json = ($out | Out-String).Trim() | ConvertFrom-Json
            $json.message | Should -Be 'hello'
            $json.level | Should -Be 'Information'
            $json.correlationId | Should -Be 'abc'
        }
    }
}
