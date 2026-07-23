#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulesDir = Join-Path $PSScriptRoot '..' 'modules'
    if (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $modulesDir) {
        $env:PSModulePath = $modulesDir + [IO.Path]::PathSeparator + $env:PSModulePath
    }
    Import-Module 'AT.Common' -Force
    Import-Module 'AT.Core' -Force
    Import-Module 'AT.Providers.Intune' -Force
    Import-Module 'AT.Providers.EntraId' -Force
}

Describe 'Select-FreshestManagedDevice' {
    It 'picks the device with the most recent enrolledDateTime' {
        $devices = @(
            [pscustomobject]@{ id = 'a'; enrolledDateTime = '2024-01-01T00:00:00Z'; lastSyncDateTime = '2024-06-01T00:00:00Z' },
            [pscustomobject]@{ id = 'b'; enrolledDateTime = '2024-05-01T00:00:00Z'; lastSyncDateTime = '2024-02-01T00:00:00Z' }
        )
        (Select-FreshestManagedDevice -Devices $devices).id | Should -Be 'b'
    }

    It 'falls back to lastSyncDateTime when enrolledDateTime ties' {
        $devices = @(
            [pscustomobject]@{ id = 'a'; enrolledDateTime = '2024-01-01T00:00:00Z'; lastSyncDateTime = '2024-06-01T00:00:00Z' },
            [pscustomobject]@{ id = 'b'; enrolledDateTime = '2024-01-01T00:00:00Z'; lastSyncDateTime = '2024-02-01T00:00:00Z' }
        )
        (Select-FreshestManagedDevice -Devices $devices).id | Should -Be 'a'
    }

    It 'treats null enrolledDateTime as oldest' {
        $devices = @(
            [pscustomobject]@{ id = 'a'; enrolledDateTime = $null; lastSyncDateTime = $null },
            [pscustomobject]@{ id = 'b'; enrolledDateTime = '2024-01-01T00:00:00Z'; lastSyncDateTime = $null }
        )
        (Select-FreshestManagedDevice -Devices $devices).id | Should -Be 'b'
    }

    It 'returns the single device when only one candidate' {
        $devices = @([pscustomobject]@{ id = 'solo'; enrolledDateTime = $null; lastSyncDateTime = $null })
        (Select-FreshestManagedDevice -Devices $devices).id | Should -Be 'solo'
    }
}

Describe 'Intune destructive actions honour DryRun' {
    It 'Invoke-IntuneWipe returns DryRun without calling Graph' {
        Mock -CommandName Invoke-GraphRequest -ModuleName AT.Providers.Intune -MockWith { throw 'should not be called' }
        $r = Invoke-IntuneWipe -ManagedDeviceId 'dev1' -DryRun
        $r.Outcome | Should -Be 'DryRun'
        Should -Invoke Invoke-GraphRequest -ModuleName AT.Providers.Intune -Times 0
    }

    It 'Invoke-IntuneWipe issues the wipe when not DryRun' {
        Mock -CommandName Invoke-GraphRequest -ModuleName AT.Providers.Intune -MockWith { return $null }
        $r = Invoke-IntuneWipe -ManagedDeviceId 'dev1'
        $r.Outcome | Should -Be 'Issued'
        Should -Invoke Invoke-GraphRequest -ModuleName AT.Providers.Intune -Times 1
    }

    It 'Invoke-IntuneRetire returns DryRun without calling Graph' {
        Mock -CommandName Invoke-GraphRequest -ModuleName AT.Providers.Intune -MockWith { throw 'should not be called' }
        (Invoke-IntuneRetire -ManagedDeviceId 'dev1' -DryRun).Outcome | Should -Be 'DryRun'
    }

    It 'Remove-AutopilotDevice skips when no serial supplied' {
        (Remove-AutopilotDevice -SerialNumber '').Outcome | Should -Be 'Skipped'
    }
}

Describe 'Entra ID provider' {
    It 'Remove-EntraDevice skips when device not resolvable' {
        Mock -CommandName Invoke-GraphRequest -ModuleName AT.Providers.EntraId -MockWith {
            [pscustomobject]@{ value = @() }
        }
        $ctx = New-DeviceContext -Record ([pscustomobject]@{ deviceName = 'PC-404' })
        (Remove-EntraDevice -Context $ctx).Status | Should -Be 'Skipped'
    }

    It 'Remove-EntraDevice returns Skipped DryRun without deleting' {
        Mock -CommandName Invoke-GraphRequest -ModuleName AT.Providers.EntraId -MockWith {
            param($Method, $Path)
            if ($Method -eq 'DELETE') { throw 'should not delete in dry-run' }
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 'obj-1' }) }
        }
        $ctx = New-DeviceContext -Record ([pscustomobject]@{ deviceName = 'PC-1' })
        $r = Remove-EntraDevice -Context $ctx -DryRun
        $r.Status | Should -Be 'Skipped'
        $r.Detail | Should -Match 'DRY-RUN'
    }

    It 'Remove-EntraDevice deletes a resolved object and reports success' {
        Mock -CommandName Invoke-GraphRequest -ModuleName AT.Providers.EntraId -MockWith {
            param($Method, $Path)
            if ($Method -eq 'DELETE') { return $null }
            [pscustomobject]@{ value = @([pscustomobject]@{ id = 'obj-9' }) }
        }
        $ctx = New-DeviceContext -Record ([pscustomobject]@{ entraDeviceId = 'obj-9' })
        $r = Remove-EntraDevice -Context $ctx
        $r.Status | Should -Be 'Success'
        $r.Detail | Should -Match 'obj-9'
    }

    It 'Resolve-EntraDeviceObjectId prefers explicit EntraDeviceId' {
        $ctx = New-DeviceContext -Record ([pscustomobject]@{ entraDeviceId = 'explicit-id'; deviceName = 'PC-X' })
        Resolve-EntraDeviceObjectId -Context $ctx | Should -Be 'explicit-id'
    }
}

Describe 'Intune reconciliation status' {
    # Uses InModuleScope so the mocked Get-IntuneManagedDevice and the function under test
    # resolve in the same module instance (Mock -ModuleName is import-order flaky in the
    # full suite — see AT.Infrastructure idempotency tests for the same pattern).
    It 'Get-IntuneWipeStatus reports Success when the device is gone' {
        InModuleScope 'AT.Providers.Intune' {
            Mock -CommandName Get-IntuneManagedDevice -MockWith { $null }
            (Get-IntuneWipeStatus -Context ([pscustomobject]@{ IntuneDeviceId = 'x' })).Status | Should -Be 'Success'
        }
    }
    It 'Get-IntuneWipeStatus reports a hard failure on wipeFailed management state' {
        InModuleScope 'AT.Providers.Intune' {
            Mock -CommandName Get-IntuneManagedDevice -MockWith {
                [pscustomobject]@{ id = 'x'; managementState = 'wipeFailed' }
            }
            $r = Get-IntuneWipeStatus -Context ([pscustomobject]@{ IntuneDeviceId = 'x' })
            $r.Status | Should -Be 'Failed'
            $r.Transient | Should -BeFalse
        }
    }
    It 'Get-IntuneWipeStatus reports Success when the wipe action is done' {
        InModuleScope 'AT.Providers.Intune' {
            Mock -CommandName Get-IntuneManagedDevice -MockWith {
                [pscustomobject]@{ id = 'x'; managementState = 'managed'; deviceActionResults = @(
                        [pscustomobject]@{ actionName = 'wipe'; actionState = 'done'; lastUpdatedDateTime = '2024-06-01T00:00:00Z' }
                    )
                }
            }
            (Get-IntuneWipeStatus -Context ([pscustomobject]@{ IntuneDeviceId = 'x' })).Status | Should -Be 'Success'
        }
    }
    It 'Get-IntuneWipeStatus stays transient while the wipe is pending' {
        InModuleScope 'AT.Providers.Intune' {
            Mock -CommandName Get-IntuneManagedDevice -MockWith {
                [pscustomobject]@{ id = 'x'; managementState = 'managed'; deviceActionResults = @(
                        [pscustomobject]@{ actionName = 'wipe'; actionState = 'pending'; lastUpdatedDateTime = '2024-06-01T00:00:00Z' }
                    )
                }
            }
            $r = Get-IntuneWipeStatus -Context ([pscustomobject]@{ IntuneDeviceId = 'x' })
            $r.Status | Should -Be 'Failed'
            $r.Transient | Should -BeTrue
        }
    }
    It 'Get-IntuneDeleteStatus reports Success when the object is gone' {
        InModuleScope 'AT.Providers.Intune' {
            Mock -CommandName Get-IntuneManagedDevice -MockWith { $null }
            (Get-IntuneDeleteStatus -Context ([pscustomobject]@{ IntuneDeviceId = 'x' })).Status | Should -Be 'Success'
        }
    }
    It 'Get-IntuneDeleteStatus stays transient while the object still exists' {
        InModuleScope 'AT.Providers.Intune' {
            Mock -CommandName Get-IntuneManagedDevice -MockWith { [pscustomobject]@{ id = 'x' } }
            $r = Get-IntuneDeleteStatus -Context ([pscustomobject]@{ IntuneDeviceId = 'x' })
            $r.Status | Should -Be 'Failed'
            $r.Transient | Should -BeTrue
        }
    }
}
