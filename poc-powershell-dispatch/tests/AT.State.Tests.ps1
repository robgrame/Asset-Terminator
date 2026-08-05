#Requires -Version 7.6

BeforeAll {
    Import-Module "$PSScriptRoot/../shared/Modules/AT.State.psm1" -Force
}

Describe 'Azure Table property serialization' {
    BeforeEach {
        Mock Get-StateTableUri { 'https://example.table.core.windows.net/wiperequests' } -ModuleName AT.State
        Mock Get-TableHeaders { @{} } -ModuleName AT.State
        Mock Invoke-RestMethod {} -ModuleName AT.State
    }

    It 'stores ordered dictionaries as JSON strings instead of unsupported nested entity properties' {
        $payload = [ordered]@{
            requestId = 'REQUEST-ORDERED'
            device = [ordered]@{ serialNumber = 'SERIAL-ORDERED' }
        }

        Save-WipeRequestState -Platform 'Windows' -RequestId 'REQUEST-ORDERED' -Properties @{
            status = 'Accepted'
            payloadJson = $payload
        } | Out-Null

        Should -Invoke Invoke-RestMethod -ModuleName AT.State -Times 1 -Exactly -ParameterFilter {
            $entity = $Body | ConvertFrom-Json
            $storedPayload = $entity.payloadJson | ConvertFrom-Json
            $entity.payloadJson -is [string] -and
            $storedPayload.requestId -eq 'REQUEST-ORDERED' -and
            $storedPayload.device.serialNumber -eq 'SERIAL-ORDERED'
        }
    }
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

Describe 'Remove-RequestIdIndex (idempotent, conditional index cleanup)' {
    BeforeEach {
        Mock Get-StateTableUri { 'https://example.table.core.windows.net/wiperequests' } -ModuleName AT.State
        Mock Get-TableHeaders { @{} } -ModuleName AT.State
    }

    function script:New-HttpErrorRecord {
        param([int] $StatusCode)
        $errorResponse = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]$StatusCode }
        $exception = [System.Net.Http.HttpRequestException]::new("HTTP $StatusCode")
        $exception | Add-Member -MemberType NoteProperty -Name Response -Value $errorResponse -Force
        return [System.Management.Automation.ErrorRecord]::new($exception, "Http$StatusCode", [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
    }

    It 'removes the row it owns (matching payload hash) with an ETag-conditional DELETE' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                Content = '{"PartitionKey":"__RequestId","RowKey":"REQUEST-1","platform":"Windows","payloadHash":"hash-a"}'
                Headers = @{ ETag = 'W/"index-etag-1"' }
            }
        } -ModuleName AT.State
        Mock Invoke-RestMethod {} -ModuleName AT.State

        $removed = Remove-RequestIdIndex -RequestId 'REQUEST-1' -PayloadHash 'hash-a'

        $removed | Should -BeTrue
        Should -Invoke Invoke-RestMethod -ModuleName AT.State -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'DELETE' -and $Headers['If-Match'] -eq 'W/"index-etag-1"'
        }
    }

    It 'never removes a different registration: a mismatched payload hash is left untouched (a genuine collision, not this caller''s row)' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                Content = '{"PartitionKey":"__RequestId","RowKey":"REQUEST-2","platform":"Windows","payloadHash":"hash-owned-by-someone-else"}'
                Headers = @{ ETag = 'W/"index-etag-2"' }
            }
        } -ModuleName AT.State
        Mock Invoke-RestMethod {} -ModuleName AT.State

        $removed = Remove-RequestIdIndex -RequestId 'REQUEST-2' -PayloadHash 'hash-a'

        $removed | Should -BeFalse
        Should -Invoke Invoke-RestMethod -ModuleName AT.State -Times 0 -Exactly
    }

    It 'treats an already-absent row (404 on read) as nothing left to clean up' {
        Mock Invoke-WebRequest { throw (New-HttpErrorRecord -StatusCode 404) } -ModuleName AT.State
        Mock Invoke-RestMethod {} -ModuleName AT.State

        $removed = Remove-RequestIdIndex -RequestId 'REQUEST-3' -PayloadHash 'hash-a'

        $removed | Should -BeTrue
        Should -Invoke Invoke-RestMethod -ModuleName AT.State -Times 0 -Exactly
    }

    It 'treats a 412 on the DELETE (raced with another read/delete since our GET) as nothing left to clean up, without throwing' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                Content = '{"PartitionKey":"__RequestId","RowKey":"REQUEST-4","platform":"Windows","payloadHash":"hash-a"}'
                Headers = @{ ETag = 'W/"stale-etag"' }
            }
        } -ModuleName AT.State
        Mock Invoke-RestMethod { throw (New-HttpErrorRecord -StatusCode 412) } -ModuleName AT.State

        $removed = Remove-RequestIdIndex -RequestId 'REQUEST-4' -PayloadHash 'hash-a'

        $removed | Should -BeTrue
    }

    It 'treats a 404 on the DELETE (row deleted by someone else between our read and delete) as nothing left to clean up' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                Content = '{"PartitionKey":"__RequestId","RowKey":"REQUEST-5","platform":"Windows","payloadHash":"hash-a"}'
                Headers = @{ ETag = 'W/"etag-5"' }
            }
        } -ModuleName AT.State
        Mock Invoke-RestMethod { throw (New-HttpErrorRecord -StatusCode 404) } -ModuleName AT.State

        $removed = Remove-RequestIdIndex -RequestId 'REQUEST-5' -PayloadHash 'hash-a'

        $removed | Should -BeTrue
    }

    It 'rethrows an unexpected GET failure instead of silently treating it as "nothing to clean up"' {
        Mock Invoke-WebRequest { throw (New-HttpErrorRecord -StatusCode 500) } -ModuleName AT.State
        Mock Invoke-RestMethod {} -ModuleName AT.State

        { Remove-RequestIdIndex -RequestId 'REQUEST-6' -PayloadHash 'hash-a' } | Should -Throw

        Should -Invoke Invoke-RestMethod -ModuleName AT.State -Times 0 -Exactly
    }

    It 'rethrows an unexpected DELETE failure instead of silently treating it as removed' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                Content = '{"PartitionKey":"__RequestId","RowKey":"REQUEST-7","platform":"Windows","payloadHash":"hash-a"}'
                Headers = @{ ETag = 'W/"etag-7"' }
            }
        } -ModuleName AT.State
        Mock Invoke-RestMethod { throw (New-HttpErrorRecord -StatusCode 500) } -ModuleName AT.State

        { Remove-RequestIdIndex -RequestId 'REQUEST-7' -PayloadHash 'hash-a' } | Should -Throw
    }

    It 'is safe to call twice in a row: the second call finds the row already gone and still returns $true' {
        $script:callCount = 0
        Mock Invoke-WebRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                return [pscustomobject]@{
                    Content = '{"PartitionKey":"__RequestId","RowKey":"REQUEST-8","platform":"Windows","payloadHash":"hash-a"}'
                    Headers = @{ ETag = 'W/"etag-8"' }
                }
            }
            throw (New-HttpErrorRecord -StatusCode 404)
        } -ModuleName AT.State
        Mock Invoke-RestMethod {} -ModuleName AT.State

        $first = Remove-RequestIdIndex -RequestId 'REQUEST-8' -PayloadHash 'hash-a'
        $second = Remove-RequestIdIndex -RequestId 'REQUEST-8' -PayloadHash 'hash-a'

        $first | Should -BeTrue
        $second | Should -BeTrue
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
