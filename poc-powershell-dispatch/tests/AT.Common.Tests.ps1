#Requires -Version 7.6

BeforeAll {
    Import-Module "$PSScriptRoot/../shared/Modules/AT.Common.psm1" -Force
}

Describe 'Get-JsonPropertyValue' {
    It 'reads values from a hashtable body' {
        Get-JsonPropertyValue -InputObject @{ serialNumber = 'HASH-1' } -Name 'serialNumber' |
            Should -Be 'HASH-1'
    }

    It 'reads values from a PSCustomObject body' {
        Get-JsonPropertyValue -InputObject ([pscustomobject]@{ serialNumber = 'OBJECT-1' }) -Name 'serialNumber' |
            Should -Be 'OBJECT-1'
    }

    It 'reads primitive values from an Azure Functions JObject body' {
        Add-Type -AssemblyName Newtonsoft.Json
        $body = [Newtonsoft.Json.Linq.JObject]::Parse('{"serialNumber":"JOBJECT-1","dryRun":false}')

        Get-JsonPropertyValue -InputObject $body -Name 'serialNumber' | Should -Be 'JOBJECT-1'
        Get-JsonPropertyValue -InputObject $body -Name 'dryRun' | Should -BeFalse
        Get-JsonPropertyValue -InputObject $body -Name 'missing' | Should -BeNullOrEmpty
    }
}
