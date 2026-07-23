#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulesDir = Join-Path $PSScriptRoot '..' 'modules'
    if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $modulesDir) {
        $env:PSModulePath = $modulesDir + [IO.Path]::PathSeparator + $env:PSModulePath
    }
    Import-Module 'AT.Contracts' -Force
    Import-Module 'AT.Core' -Force

    function New-ValidRequest {
        param([hashtable] $Override = @{})
        $base = @{
            requestId        = 'SNOW-INC001'
            assetId          = 'ASSET-1'
            deviceName       = 'LAPTOP-01'
            serialNumber     = '5CG123'
            deviceType       = 'Windows'
            assetCategory    = 'Standard'
            dispositionType  = 'Terminate'
            requestedActions = @('Intune', 'Wipe')
            dryRun           = $true
        }
        foreach ($k in $Override.Keys) { $base[$k] = $Override[$k] }
        [pscustomobject]$base
    }
}

Describe 'AT.Contracts.New-DecommissionRequest' {
    It 'applies defaults for omitted fields' {
        $r = '{ "requestId": "R1", "assetId": "A1", "deviceName": "D1", "requestedActions": ["Intune"] }' | New-DecommissionRequest
        $r.dispositionType | Should -Be 'Terminate'
        $r.assetCategory   | Should -Be 'Standard'
        $r.deviceType      | Should -Be 'Windows'
        $r.dryRun          | Should -BeFalse
    }
    It 'preserves provided values' {
        $r = New-DecommissionRequest -InputObject ([pscustomobject]@{ requestId='R'; assetId='A'; dispositionType='Retire'; dryRun=$true; requestedActions=@('Intune') })
        $r.dispositionType | Should -Be 'Retire'
        $r.dryRun | Should -BeTrue
    }
}

Describe 'AT.Core.Test-DecommissionRequest' {
    It 'accepts a valid request' {
        Test-DecommissionRequest (New-ValidRequest) | Should -BeNullOrEmpty
    }
    It 'requires requestId' {
        Test-DecommissionRequest (New-ValidRequest @{ requestId = '' }) | Should -Match 'requestId'
    }
    It 'requires at least one action' {
        Test-DecommissionRequest (New-ValidRequest @{ requestedActions = @() }) | Should -Match 'requestedActions'
    }
    It 'requires deviceName or serialNumber' {
        Test-DecommissionRequest (New-ValidRequest @{ deviceName = ''; serialNumber = '' }) | Should -Match 'deviceName or serialNumber'
    }
    It 'rejects invalid deviceType' {
        Test-DecommissionRequest (New-ValidRequest @{ deviceType = 'Linux' }) | Should -Match 'deviceType is invalid'
    }
    It 'rejects Retire disposition with Wipe action' {
        Test-DecommissionRequest (New-ValidRequest @{ dispositionType = 'Retire'; requestedActions = @('Intune','Wipe') }) | Should -Match 'Retire cannot include'
    }
    It 'rejects Terminate disposition with Retire action' {
        Test-DecommissionRequest (New-ValidRequest @{ requestedActions = @('Intune','Retire') }) | Should -Match 'cannot include the Retire action'
    }
    It 'requires serialNumber for Autopilot' {
        Test-DecommissionRequest (New-ValidRequest @{ serialNumber=''; requestedActions=@('Autopilot','Wipe') }) | Should -Match 'serialNumber is required'
    }
}

Describe 'AT.Core.Resolve-DecommissionTarget' {
    It 'auto-injects pre-wipe actions for a Windows Terminate wipe' {
        $t = Resolve-DecommissionTarget (New-ValidRequest)
        $t | Should -Contain 'Autopilot'
        $t | Should -Contain 'LicenseRemoval'
        $t | Should -Contain 'BiosPasswordRemoval'
    }
    It 'honors disabled pre-wipe flags' {
        $t = Resolve-DecommissionTarget (New-ValidRequest) -PreWipe @{ DeleteFromAutopilot=$false; RemoveEnterpriseLicense=$false; RemoveBiosPassword=$false }
        $t | Should -Not -Contain 'Autopilot'
        $t | Should -Not -Contain 'LicenseRemoval'
    }
    It 'adds Retire and removes Wipe for a Retire disposition' {
        $t = Resolve-DecommissionTarget (New-ValidRequest @{ dispositionType='Retire'; requestedActions=@('Intune') })
        $t | Should -Contain 'Retire'
        $t | Should -Not -Contain 'Wipe'
    }
    It 'does not inject Autopilot without a serialNumber' {
        $t = Resolve-DecommissionTarget (New-ValidRequest @{ serialNumber = '' })
        $t | Should -Not -Contain 'Autopilot'
    }
}

Describe 'AT.Core.New-DecommissionRecord' {
    It 'builds a record with resolved pending actions' {
        $rec = New-DecommissionRecord -Request (New-ValidRequest) -CorrelationId 'corr-1'
        $rec.state | Should -Be 'Requested'
        $rec.correlationId | Should -Be 'corr-1'
        ($rec.actions | Where-Object target -eq 'Wipe').status | Should -Be 'Pending'
        ($rec.actions | Where-Object target -eq 'Autopilot').action | Should -Be 'DeleteAutopilot'
    }
}
