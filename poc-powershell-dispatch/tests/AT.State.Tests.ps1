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

Describe 'Register-RequestIdIndex (atomic global requestId gate)' {
    BeforeEach {
        Mock Get-StateTableUri { 'https://example.table.core.windows.net/wiperequests' } -ModuleName AT.State
        Mock Get-TableHeaders { @{} } -ModuleName AT.State
    }

    It 'registers a brand-new requestId with a single conditional INSERT' {
        Mock Invoke-RestMethod {} -ModuleName AT.State

        $registration = Register-RequestIdIndex -RequestId 'REQUEST-100' -Platform 'Windows' -PayloadHash 'hash-a'

        $registration.Registered | Should -BeTrue
        $registration.Conflict | Should -BeFalse
        Should -Invoke Invoke-RestMethod -ModuleName AT.State -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Body -match '"PartitionKey"\s*:\s*"__RequestId"' -and $Body -match '"payloadHash"\s*:\s*"hash-a"'
        }
    }

    It 'treats a replay with the identical payload hash as a safe duplicate, never overwriting the original' {
        Mock Invoke-RestMethod {
            $errorResponse = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]::Conflict }
            $exception = [System.Net.Http.HttpRequestException]::new('Conflict')
            $exception | Add-Member -MemberType NoteProperty -Name Response -Value $errorResponse -Force
            $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, 'Conflict', [System.Management.Automation.ErrorCategory]::ResourceExists, $null)
            throw $errorRecord
        } -ModuleName AT.State
        Mock Get-RequestIdIndex { [pscustomobject]@{ platform = 'Windows'; payloadHash = 'hash-a' } } -ModuleName AT.State

        $registration = Register-RequestIdIndex -RequestId 'REQUEST-101' -Platform 'Windows' -PayloadHash 'hash-a'

        $registration.Registered | Should -BeFalse
        $registration.Conflict | Should -BeFalse
        $registration.Platform | Should -Be 'Windows'
    }

    It 'reports a conflict (without overwriting) when the same requestId is reused with different content' {
        Mock Invoke-RestMethod {
            $errorResponse = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]::Conflict }
            $exception = [System.Net.Http.HttpRequestException]::new('Conflict')
            $exception | Add-Member -MemberType NoteProperty -Name Response -Value $errorResponse -Force
            $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, 'Conflict', [System.Management.Automation.ErrorCategory]::ResourceExists, $null)
            throw $errorRecord
        } -ModuleName AT.State
        Mock Get-RequestIdIndex { [pscustomobject]@{ platform = 'Windows'; payloadHash = 'hash-a' } } -ModuleName AT.State

        $registration = Register-RequestIdIndex -RequestId 'REQUEST-101' -Platform 'Windows' -PayloadHash 'hash-b-different'

        $registration.Registered | Should -BeFalse
        $registration.Conflict | Should -BeTrue
    }
}

Describe 'Set-WipeRequestStateClaim (atomic ETag claim)' {
    BeforeEach {
        Mock Get-StateTableUri { 'https://example.table.core.windows.net/wiperequests' } -ModuleName AT.State
        Mock Get-TableHeaders { @{} } -ModuleName AT.State
    }

    It 'succeeds the MERGE with an If-Match header carrying the supplied ETag' {
        Mock Invoke-RestMethod {} -ModuleName AT.State

        $claimed = Set-WipeRequestStateClaim -Platform 'Windows' -RequestId 'REQUEST-200' -ETag 'W/"etag-1"' -Properties @{ status = 'Dispatching' }

        $claimed | Should -BeTrue
        Should -Invoke Invoke-RestMethod -ModuleName AT.State -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'MERGE' -and $Headers['If-Match'] -eq 'W/"etag-1"'
        }
    }

    It 'returns $false (does not throw) on a 412 precondition failure, meaning another worker already claimed the row' {
        Mock Invoke-RestMethod {
            $errorResponse = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]::PreconditionFailed }
            $exception = [System.Net.Http.HttpRequestException]::new('Precondition Failed')
            $exception | Add-Member -MemberType NoteProperty -Name Response -Value $errorResponse -Force
            $errorRecord = [System.Management.Automation.ErrorRecord]::new($exception, 'PreconditionFailed', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $null)
            throw $errorRecord
        } -ModuleName AT.State

        $claimed = Set-WipeRequestStateClaim -Platform 'Windows' -RequestId 'REQUEST-201' -ETag 'W/"stale-etag"' -Properties @{ status = 'Dispatching' }

        $claimed | Should -BeFalse
    }
}

