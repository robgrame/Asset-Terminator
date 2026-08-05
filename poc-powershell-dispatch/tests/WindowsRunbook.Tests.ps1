#Requires -Version 7.6

BeforeAll {
    $runbookPath = Join-Path $PSScriptRoot '../runbooks/RBK-WindowsDisposal.ps1'
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $runbookPath,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) { throw ($errors -join [Environment]::NewLine) }

    foreach ($functionName in @('Get-GraphErrorStatusCode', 'Invoke-ManagedDeviceNudge')) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
        if (-not $functionAst) { throw "Function '$functionName' was not found in the Windows runbook." }
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    function Invoke-GraphRequestSafe {
        param(
            [string] $Uri,
            [string] $Method,
            [object] $Body,
            [string] $ContentType
        )
    }

    function New-GraphHttpError {
        param([int] $StatusCode)
        $response = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]$StatusCode }
        $exception = [System.Net.Http.HttpRequestException]::new("HTTP $StatusCode")
        $exception | Add-Member -MemberType NoteProperty -Name Response -Value $response -Force
        return [System.Management.Automation.ErrorRecord]::new(
            $exception,
            "Http$StatusCode",
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $null
        )
    }
}

Describe 'Windows post-wipe nudges' {
    BeforeEach {
        $script:capturedUri = $null
        $script:capturedMethod = $null
        Mock Invoke-GraphRequestSafe {
            $script:capturedUri = $Uri
            $script:capturedMethod = $Method
        }
        Mock Start-Sleep {}
    }

    It 'issues syncDevice through Microsoft Graph' {
        $result = Invoke-ManagedDeviceNudge -ManagedDeviceId 'device-1' -Action 'syncDevice'

        $result.Issued | Should -BeTrue
        $result.Attempts | Should -Be 1
        Should -Invoke Invoke-GraphRequestSafe -Times 1 -Exactly
        $script:capturedMethod | Should -Be 'POST'
        $script:capturedUri | Should -Match '/managedDevices/device-1/syncDevice$'
    }

    It 'retries a transient Graph failure and then succeeds' {
        $script:attempt = 0
        Mock Invoke-GraphRequestSafe {
            $script:attempt++
            if ($script:attempt -eq 1) { throw (New-GraphHttpError -StatusCode 503) }
        }

        $result = Invoke-ManagedDeviceNudge -ManagedDeviceId 'device-2' -Action 'rebootNow' -MaxAttempts 3

        $result.Issued | Should -BeTrue
        $result.Attempts | Should -Be 2
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 1 }
    }

    It 'does not retry a permanent Graph failure' {
        Mock Invoke-GraphRequestSafe { throw (New-GraphHttpError -StatusCode 400) }

        $result = Invoke-ManagedDeviceNudge -ManagedDeviceId 'device-3' -Action 'syncDevice' -MaxAttempts 3

        $result.Issued | Should -BeFalse
        $result.Attempts | Should -Be 1
        Should -Invoke Invoke-GraphRequestSafe -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
}
