#Requires -Version 7.6

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot 'Invoke-DispatchE2EDirect.ps1'
    $tokens = $null
    $errors = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) { throw ($errors -join [Environment]::NewLine) }
}

Describe 'Direct E2E entry point' {
    It 'does not invoke Azure CLI or Azure PowerShell commands' {
        $commands = @($script:ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object { $_.GetCommandName() })

        $commands | Should -Not -Contain 'az'
        @($commands | Where-Object { $_ -match '^(Get|Set|New|Invoke)-Az' }).Count | Should -Be 0
    }

    It 'delegates to the complete E2E implementation in direct mode' {
        $source = $script:ast.Extent.Text

        $source | Should -Match 'Invoke-DispatchE2E\.ps1'
        $source | Should -Match 'BaseUri'
        $source | Should -Match 'FunctionKey'
        $source | Should -Match 'if \(\$Real\.IsPresent\)'
    }
}
