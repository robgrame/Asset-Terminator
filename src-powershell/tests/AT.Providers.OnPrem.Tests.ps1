#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulesDir = Join-Path $PSScriptRoot '..' 'modules'
    if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $modulesDir) {
        $env:PSModulePath = $modulesDir + [IO.Path]::PathSeparator + $env:PSModulePath
    }
    Import-Module 'AT.Common' -Force
    Import-Module 'AT.Core' -Force
    Import-Module 'AT.Providers.ActiveDirectory' -Force
    Import-Module 'AT.Providers.ConfigMgr' -Force
    Import-Module 'AT.Providers.DeviceActions' -Force
}

Describe 'ConfigMgr: pure helpers' {
    It 'normalizes an FQDN to the bare NetBIOS name' {
        ConvertTo-SccmDeviceName -DeviceName 'PC01.contoso.com' | Should -Be 'PC01'
        ConvertTo-SccmDeviceName -DeviceName 'PC01' | Should -Be 'PC01'
        ConvertTo-SccmDeviceName -DeviceName '  ' | Should -BeNullOrEmpty
    }

    It 'extracts the first ResourceId from an OData value array' {
        $content = [pscustomobject]@{ value = @([pscustomobject]@{ ResourceId = 16777345 }) }
        Get-SccmResourceIdFromResponse -Content $content | Should -Be 16777345
    }

    It 'extracts a ResourceId from a direct object and parses strings' {
        Get-SccmResourceIdFromResponse -Content ([pscustomobject]@{ ResourceId = '42' }) | Should -Be 42
    }

    It 'returns null when no ResourceId present' {
        Get-SccmResourceIdFromResponse -Content ([pscustomobject]@{ value = @() }) | Should -BeNullOrEmpty
    }

    It 'classifies transient statuses (0/408/5xx) as transient' {
        Test-SccmTransientStatus -StatusCode 0 | Should -BeTrue
        Test-SccmTransientStatus -StatusCode 408 | Should -BeTrue
        Test-SccmTransientStatus -StatusCode 503 | Should -BeTrue
        Test-SccmTransientStatus -StatusCode 404 | Should -BeFalse
        Test-SccmTransientStatus -StatusCode 200 | Should -BeFalse
    }
}

Describe 'ConfigMgr: Find-SccmDeviceResourceId' {
    It 'queries by name first and returns the resource id' {
        Mock -ModuleName 'AT.Providers.ConfigMgr' Invoke-SccmRequest {
            @{ StatusCode = 200; Content = [pscustomobject]@{ value = @([pscustomobject]@{ ResourceId = 5 }) } }
        }
        Find-SccmDeviceResourceId -BaseUrl 'https://sccm/AdminService' -DeviceName 'PC01' | Should -Be 5
    }

    It 'falls back to serial number when name yields nothing' {
        Mock -ModuleName 'AT.Providers.ConfigMgr' Invoke-SccmRequest {
            param($Method, $Uri)
            if ($Uri -match 'SerialNumber') { return @{ StatusCode = 200; Content = [pscustomobject]@{ value = @([pscustomobject]@{ ResourceId = 9 }) } } }
            return @{ StatusCode = 404; Content = $null }
        }
        Find-SccmDeviceResourceId -BaseUrl 'https://sccm/AdminService' -DeviceName 'PC01' -SerialNumber 'ABC' | Should -Be 9
    }

    It 'returns null when neither lookup matches' {
        Mock -ModuleName 'AT.Providers.ConfigMgr' Invoke-SccmRequest { @{ StatusCode = 404; Content = $null } }
        Find-SccmDeviceResourceId -BaseUrl 'https://sccm/AdminService' -DeviceName 'PC01' -SerialNumber 'ABC' | Should -BeNullOrEmpty
    }
}

Describe 'ConfigMgr: Remove-SccmDevice' {
    It 'skips when the device is not found' {
        Mock -ModuleName 'AT.Providers.ConfigMgr' Find-SccmDeviceResourceId { $null }
        $r = Remove-SccmDevice -Context ([pscustomobject]@{ DeviceName = 'PC01' }) -BaseUrl 'https://sccm'
        $r.Status | Should -Be 'Skipped'
    }

    It 'honours DryRun without deleting' {
        Mock -ModuleName 'AT.Providers.ConfigMgr' Find-SccmDeviceResourceId { 7 }
        Mock -ModuleName 'AT.Providers.ConfigMgr' Remove-SccmDeviceResource { throw 'should not be called' }
        $r = Remove-SccmDevice -Context ([pscustomobject]@{ DeviceName = 'PC01' }) -BaseUrl 'https://sccm' -DryRun
        $r.Status | Should -Be 'Success'
        $r.Detail | Should -Match 'DRY-RUN'
    }

    It 'deletes and returns success' {
        Mock -ModuleName 'AT.Providers.ConfigMgr' Find-SccmDeviceResourceId { 7 }
        Mock -ModuleName 'AT.Providers.ConfigMgr' Remove-SccmDeviceResource { }
        $r = Remove-SccmDevice -Context ([pscustomobject]@{ DeviceName = 'PC01' }) -BaseUrl 'https://sccm'
        $r.Status | Should -Be 'Success'
        $r.Detail | Should -Match 'deleted resourceId 7'
    }
}

Describe 'ConfigMgr: Get-SccmDeviceStatus' {
    It 'reports success once the device is gone' {
        Mock -ModuleName 'AT.Providers.ConfigMgr' Find-SccmDeviceResourceId { $null }
        (Get-SccmDeviceStatus -Context ([pscustomobject]@{ DeviceName = 'PC01' }) -BaseUrl 'https://sccm').Status | Should -Be 'Success'
    }

    It 'reports a transient failure while the device still exists' {
        Mock -ModuleName 'AT.Providers.ConfigMgr' Find-SccmDeviceResourceId { 3 }
        $r = Get-SccmDeviceStatus -Context ([pscustomobject]@{ DeviceName = 'PC01' }) -BaseUrl 'https://sccm'
        $r.Status | Should -Be 'Failed'
        $r.Transient | Should -BeTrue
    }
}

Describe 'DeviceActions: pure helpers' {
    It 'substitutes context placeholders case-insensitively' {
        $ctx = [pscustomobject]@{ SerialNumber = 'SN9'; DeviceName = 'PC01'; PrimaryUserUpn = 'u@x' }
        Expand-CommandTemplate -Template '/s {SerialNumber} /d {deviceName} /u {PRIMARYUSERUPN}' -Context $ctx |
            Should -Be '/s SN9 /d PC01 /u u@x'
    }

    It 'treats a spec with a filename as configured' {
        Test-CommandSpecConfigured -Spec ([pscustomobject]@{ FileName = 'x.exe' }) | Should -BeTrue
        Test-CommandSpecConfigured -Spec ([pscustomobject]@{ FileName = '' }) | Should -BeFalse
        Test-CommandSpecConfigured -Spec $null | Should -BeFalse
    }

    It 'resolves manufacturer from a signal, then default' {
        $ctx = [pscustomobject]@{ Signals = @{ Manufacturer = 'Dell' } }
        Resolve-DeviceManufacturer -Context $ctx -DefaultManufacturer 'HP' | Should -Be 'Dell'
        Resolve-DeviceManufacturer -Context ([pscustomobject]@{ Signals = @{} }) -DefaultManufacturer 'HP' | Should -Be 'HP'
        Resolve-DeviceManufacturer -Context ([pscustomobject]@{ }) -DefaultManufacturer '' | Should -BeNullOrEmpty
    }

    It 'maps command outcomes to provider results' {
        $timeout = ConvertTo-DeviceActionResult -Outcome @{ TimedOut = $true; Success = $false; ExitCode = -1; Output = '' } `
            -SuccessDetail 's' -TimeoutDetail 'timed out' -FailDetailPrefix 'failed'
        $timeout.Status | Should -Be 'Failed'; $timeout.Transient | Should -BeTrue

        $ok = ConvertTo-DeviceActionResult -Outcome @{ TimedOut = $false; Success = $true; ExitCode = 0; Output = '' } `
            -SuccessDetail 'done' -TimeoutDetail 't' -FailDetailPrefix 'f'
        $ok.Status | Should -Be 'Success'; $ok.Detail | Should -Match 'exit 0'

        $bad = ConvertTo-DeviceActionResult -Outcome @{ TimedOut = $false; Success = $false; ExitCode = 5; Output = 'boom' } `
            -SuccessDetail 's' -TimeoutDetail 't' -FailDetailPrefix 'failed'
        $bad.Status | Should -Be 'Failed'; $bad.Transient | Should -BeFalse; $bad.Detail | Should -Match 'boom'
    }
}

Describe 'DeviceActions: providers honour config + DryRun' {
    It 'skips license removal when not configured' {
        $opts = [pscustomobject]@{ DryRun = $false; LicenseRemoval = [pscustomobject]@{ FileName = '' } }
        (Invoke-LicenseRemoval -Context ([pscustomobject]@{ }) -Options $opts).Status | Should -Be 'Skipped'
    }

    It 'simulates license removal in DryRun' {
        $opts = [pscustomobject]@{ DryRun = $true; LicenseRemoval = [pscustomobject]@{ FileName = 'changepk.exe' } }
        $r = Invoke-LicenseRemoval -Context ([pscustomobject]@{ }) -Options $opts
        $r.Status | Should -Be 'Success'; $r.Detail | Should -Match 'DRY-RUN'
    }

    It 'skips BIOS removal when manufacturer unknown' {
        $opts = [pscustomobject]@{ DryRun = $true; DefaultManufacturer = ''; BiosPasswordRemoval = @{} }
        (Invoke-BiosPasswordRemoval -Context ([pscustomobject]@{ }) -Options $opts).Status | Should -Be 'Skipped'
    }

    It 'skips BIOS removal when no tool configured for the manufacturer' {
        $opts = [pscustomobject]@{ DryRun = $true; DefaultManufacturer = 'Dell'; BiosPasswordRemoval = @{ Dell = [pscustomobject]@{ FileName = '' } } }
        (Invoke-BiosPasswordRemoval -Context ([pscustomobject]@{ }) -Options $opts).Status | Should -Be 'Skipped'
    }

    It 'simulates BIOS removal in DryRun for the resolved manufacturer' {
        $opts = [pscustomobject]@{ DryRun = $true; DefaultManufacturer = 'Dell'; BiosPasswordRemoval = @{ Dell = [pscustomobject]@{ FileName = 'cctk.exe' } } }
        $r = Invoke-BiosPasswordRemoval -Context ([pscustomobject]@{ }) -Options $opts
        $r.Status | Should -Be 'Success'; $r.Detail | Should -Match 'Dell'
    }

    It 'pending status is transient' {
        $r = Get-DeviceActionPendingStatus
        $r.Status | Should -Be 'Failed'; $r.Transient | Should -BeTrue
    }
}

Describe 'ActiveDirectory: Remove-AdComputer / status' {
    It 'skips when the computer is not in AD' {
        Mock -ModuleName 'AT.Providers.ActiveDirectory' Find-AdComputerDistinguishedName { $null }
        (Remove-AdComputer -Context ([pscustomobject]@{ DeviceName = 'PC01' })).Status | Should -Be 'Skipped'
    }

    It 'honours DryRun without deleting' {
        Mock -ModuleName 'AT.Providers.ActiveDirectory' Find-AdComputerDistinguishedName { 'CN=PC01,OU=X,DC=c,DC=com' }
        Mock -ModuleName 'AT.Providers.ActiveDirectory' Remove-AdComputerByDistinguishedName { throw 'should not delete' }
        $r = Remove-AdComputer -Context ([pscustomobject]@{ DeviceName = 'PC01' }) -DryRun
        $r.Status | Should -Be 'Success'; $r.Detail | Should -Match 'DRY-RUN'
    }

    It 'deletes and returns success' {
        Mock -ModuleName 'AT.Providers.ActiveDirectory' Find-AdComputerDistinguishedName { 'CN=PC01,DC=c,DC=com' }
        Mock -ModuleName 'AT.Providers.ActiveDirectory' Remove-AdComputerByDistinguishedName { }
        (Remove-AdComputer -Context ([pscustomobject]@{ DeviceName = 'PC01' })).Status | Should -Be 'Success'
    }

    It 'status is success when gone, transient failure when present' {
        Mock -ModuleName 'AT.Providers.ActiveDirectory' Find-AdComputerDistinguishedName { $null }
        (Get-AdComputerStatus -Context ([pscustomobject]@{ DeviceName = 'PC01' })).Status | Should -Be 'Success'
        Mock -ModuleName 'AT.Providers.ActiveDirectory' Find-AdComputerDistinguishedName { 'CN=PC01,DC=c,DC=com' }
        $r = Get-AdComputerStatus -Context ([pscustomobject]@{ DeviceName = 'PC01' })
        $r.Status | Should -Be 'Failed'; $r.Transient | Should -BeTrue
    }
}
