#Requires -Version 7.6

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    & (Join-Path $root 'build.ps1') -Clean

    $script:GeneratedFunctions = @(
        'api/WipeIntake/run.ps1'
        'api/GetStatus/run.ps1'
        'worker/DispatchWindows/run.ps1'
        'worker/DispatchApple/run.ps1'
        'worker/DispatchAndroid/run.ps1'
        'worker/JobMonitor/run.ps1'
    )
}

Describe 'Generated Function scripts' {
    It 'writes directly readable functions without module-loading infrastructure' {
        foreach ($relativePath in $GeneratedFunctions) {
            $path = Join-Path $root $relativePath
            $source = Get-Content $path -Raw
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref] $tokens,
                [ref] $parseErrors
            )
            $functions = @($ast.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
                $true
            ))

            $source | Should -Match '(?m)^# region Inlined functions from: AT\.[A-Za-z]+\.psm1\r?$'
            $source | Should -Not -Match '(?m)^[ \t]*Import-Module\b'
            $source | Should -Not -Match '(?m)^[ \t]*(?:Export-ModuleMember|New-Module)\b'
            $source | Should -Not -Match '\$embeddedSource\b'
            $parseErrors.Count | Should -Be 0
            $functions.Count | Should -BeGreaterThan 0
            @($functions | Group-Object Name | Where-Object Count -gt 1).Count | Should -Be 0
        }
    }
}
