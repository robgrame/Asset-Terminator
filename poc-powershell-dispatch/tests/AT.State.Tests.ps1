#Requires -Version 7.6

BeforeAll {
    Import-Module "$PSScriptRoot/../shared/Modules/AT.State.psm1" -Force
}

Describe 'Device disposal lease' {
    BeforeEach {
        Mock Get-StateTableUri { 'https://example.table.core.windows.net/wiperequests' } -ModuleName AT.State
        Mock Get-TableHeaders { @{} } -ModuleName AT.State
        Mock Invoke-RestMethod {} -ModuleName AT.State
    }

    It 'atomically creates one lease row for the device serial number' {
        $result = Lock-WipeDevice -SerialNumber 'SERIAL-1' -RequestId 'REQUEST-1' -Platform 'Windows'

        $result.Acquired | Should -BeTrue
        $result.ActiveRequestId | Should -Be 'REQUEST-1'
        Should -Invoke Invoke-RestMethod -ModuleName AT.State -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and
            $Uri -eq 'https://example.table.core.windows.net/wiperequests' -and
            $Body -match '"PartitionKey"\s*:\s*"__DeviceLease"' -and
            $Body -match '"requestId"\s*:\s*"REQUEST-1"'
        }
    }

    It 'deletes only the lease owned by the completing request' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                Content = '{"requestId":"REQUEST-1"}'
                Headers = @{ ETag = 'W/"lease-etag"' }
            }
        } -ModuleName AT.State

        $removed = Unlock-WipeDevice -SerialNumber 'SERIAL-1' -RequestId 'REQUEST-1'

        $removed | Should -BeTrue
        Should -Invoke Invoke-RestMethod -ModuleName AT.State -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'DELETE' -and $Headers['If-Match'] -eq 'W/"lease-etag"'
        }
    }
}
