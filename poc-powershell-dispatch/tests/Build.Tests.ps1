#Requires -Version 7.6

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    & (Join-Path $root 'build.ps1') -Clean

    $script:GeneratedFunctions = @(
        'api/WipeIntake/handler.ps1'
        'api/GetStatus/handler.ps1'
        'api/JobMonitor/handler.ps1'
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

    It 'builds only the three functions hosted by the single app' {
        @(Get-ChildItem -Path (Join-Path $root 'api') -Filter 'handler.ps1' -Recurse -File).Count | Should -Be 3
        @(Get-ChildItem -Path (Join-Path $root 'api') -Filter 'run.ps1' -Recurse -File).Count | Should -Be 0
        Test-Path (Join-Path $root 'worker') | Should -BeFalse
    }
}
