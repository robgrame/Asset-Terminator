#Requires -Version 7.6

BeforeAll {
    Import-Module "$PSScriptRoot/../shared/Modules/AT.Graph.psm1" -Force

    function New-GraphHttpError {
        param([int] $StatusCode)
        $errorResponse = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]$StatusCode }
        $exception = [System.Net.Http.HttpRequestException]::new("HTTP $StatusCode")
        $exception | Add-Member -MemberType NoteProperty -Name Response -Value $errorResponse -Force
        return [System.Management.Automation.ErrorRecord]::new($exception, "Http$StatusCode", [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
    }
}

Describe 'Get-IntuneManagedDevice: Graph errors are never reinterpreted as "not managed"' {
    It 'returns $null for a direct managedDeviceId lookup that genuinely 404s' {
        $graphError = New-GraphHttpError -StatusCode 404
        Mock Invoke-GraphRequest { throw $graphError } -ModuleName AT.Graph

        Get-IntuneManagedDevice -ManagedDeviceId 'missing-id' | Should -BeNullOrEmpty
    }

    It 'rethrows a non-404 error from a direct managedDeviceId lookup (e.g. 403) instead of treating it as not-managed' {
        $graphError = New-GraphHttpError -StatusCode 403
        Mock Invoke-GraphRequest { throw $graphError } -ModuleName AT.Graph

        { Get-IntuneManagedDevice -ManagedDeviceId 'forbidden-id' } | Should -Throw
    }

    It 'rethrows a 401/5xx error from the filtered search instead of falling back silently' {
        $graphError = New-GraphHttpError -StatusCode 503
        Mock Invoke-GraphRequest { throw $graphError } -ModuleName AT.Graph

        { Get-IntuneManagedDevice -SerialNumber 'SERIAL-1' } | Should -Throw
    }

    It 'falls back to client-side matching only on a 400 (unsupported combined filter)' {
        $graphError = New-GraphHttpError -StatusCode 400
        $script:callCount = 0
        Mock Invoke-GraphRequest {
            param($Method, $Path)
            $script:callCount++
            if ($script:callCount -eq 1) {
                throw $graphError
            }
            return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'dev-1'; deviceName = 'DESKTOP-1'; serialNumber = 'SERIAL-1' }) }
        } -ModuleName AT.Graph
        Mock Write-MockLog {} -ModuleName AT.Graph

        $device = Get-IntuneManagedDevice -DeviceName 'DESKTOP-1' -SerialNumber 'SERIAL-1'

        $device.id | Should -Be 'dev-1'
        Should -Invoke Invoke-GraphRequest -ModuleName AT.Graph -Times 2 -Exactly
    }

    It 'returns $null (not-managed) when a filtered search genuinely finds no candidates' {
        Mock Invoke-GraphRequest { [pscustomobject]@{ value = @() } } -ModuleName AT.Graph

        Get-IntuneManagedDevice -SerialNumber 'NOT-FOUND' | Should -BeNullOrEmpty
    }
}

Describe 'Get-IntuneManagedDevice: IMEI lookup' {
    It 'resolves a device by imei alone' {
        Mock Invoke-GraphRequest {
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 'dev-2'; imei = '490154203237518'; serialNumber = 'SERIAL-2' }) }
        } -ModuleName AT.Graph

        $device = Get-IntuneManagedDevice -Imei '490154203237518'

        $device.id | Should -Be 'dev-2'
        Should -Invoke Invoke-GraphRequest -ModuleName AT.Graph -ParameterFilter { $Path -match 'imei' } -Times 1 -Exactly
    }

    It 'requires at least one identifying parameter' {
        { Get-IntuneManagedDevice } | Should -Throw
    }
}
