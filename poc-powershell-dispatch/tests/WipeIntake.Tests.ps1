#Requires -Version 7.6

# Exercises api/WipeIntake/source.ps1 directly (dot-sourced, as the Function
# App host would invoke it) with the Azure Functions PowerShell worker's
# runtime surface stubbed out (HttpResponseContext, Push-OutputBinding).
# AT.Common runs for real; AT.Graph's Get-IntuneManagedDevice and AT.State's
# functions are mocked at the point WipeIntake calls them, exactly like the
# module-level Pester conventions already used elsewhere in this repo.
#
# Focus: the pre-persistence infrastructure failures that used to leave the
# global __RequestId index permanently registered with no durable state row
# behind it (a hollow 202 forever on any same-payload retry), and the
# "Rejected persist itself failed" case that used to lie with a 422 whose
# durable row never existed.

BeforeAll {
    # Import order matters: AT.Graph.psm1 and AT.State.psm1 each internally
    # `Import-Module AT.Common.psm1 -Force`, which (being called from inside
    # another module) reloads AT.Common into that module's own scope and can
    # detach the global-scope copy of its exports. Importing AT.Common last,
    # with -Global, guarantees Write-AtLog/Write-AtAudit/etc. resolve to a
    # single global-scope module instance that WipeIntake's un-namespaced
    # top-level script (dot-sourced below) and this test file's Mocks agree on.
    Import-Module "$PSScriptRoot/../shared/Modules/AT.Graph.psm1" -Force
    Import-Module "$PSScriptRoot/../shared/Modules/AT.State.psm1" -Force
    Import-Module "$PSScriptRoot/../shared/Modules/AT.Common.psm1" -Force -Global

    # Azure Functions PowerShell worker runtime surface: never loaded outside
    # the actual Function App host, so it is stubbed here. Because no real
    # System.Net.HttpResponseContext type is loaded in this session, `using
    # namespace System.Net` inside source.ps1 resolves to this class.
    if (-not ('HttpResponseContext' -as [type])) {
        class HttpResponseContext {
            $StatusCode
            $Headers
            $Body
        }
    }

    function global:Push-OutputBinding {
        param($Name, $Value)
        $script:WipeIntakeResponse = $Value
    }

    $script:WipeIntakeSourcePath = (Resolve-Path "$PSScriptRoot/../api/WipeIntake/source.ps1").Path

    function script:Invoke-WipeIntakeRequest {
        <#
        .SYNOPSIS
            Dot-sources source.ps1 with a fake HTTP request body, exactly as
            the Functions host would invoke the trigger, and returns the
            captured HttpResponseContext.
        #>
        param([Parameter(Mandatory)] $Body)

        $script:WipeIntakeResponse = $null
        $request = [pscustomobject]@{ Body = ($Body | ConvertTo-Json -Depth 10) }
        . $script:WipeIntakeSourcePath -Request $request -TriggerMetadata @{}
        return $script:WipeIntakeResponse
    }

    function script:Get-ResponseBody {
        param($Response)
        return ($Response.Body | ConvertFrom-Json)
    }

    function script:New-ValidWipePayload {
        param([string] $RequestId = 'REQUEST-1')
        [ordered]@{
            requestId       = $RequestId
            serialNumber    = 'SERIAL-1'
            operatingSystem = 'Windows'
            scenario        = 'Disposal'
            userConfirmed   = $true
        }
    }

    function script:New-FakeManagedDevice {
        [pscustomobject]@{
            id              = 'device-1'
            serialNumber    = 'SERIAL-1'
            deviceName      = 'DEVICE-1'
            operatingSystem = 'Windows'
            osVersion       = '10.0'
            isEncrypted     = $true
            imei            = ''
        }
    }

    function script:New-AcquiredLease {
        param([string] $RequestId = 'REQUEST-1')
        [pscustomobject]@{
            Acquired        = $true
            ActiveRequestId = $RequestId
            ActivePlatform  = 'Windows'
            ExpiresAt       = (Get-Date).ToUniversalTime().AddHours(4).ToString('o')
        }
    }

    function script:New-FreshRegistration {
        [pscustomobject]@{ Registered = $true; Conflict = $false; Platform = 'Windows'; PayloadHash = 'unused' }
    }
}

Describe 'WipeIntake pre-persistence failure recovery (fail closed, no stranded index)' {
    BeforeEach {
        Mock Write-AtLog {}
        Mock Write-AtAudit {}
    }

    It 'cleans up the __RequestId index when the Graph device lookup fails, so a same-payload retry gets a full new attempt instead of a hollow 202' {
        $payload = New-ValidWipePayload -RequestId 'REQ-GRAPH-FAIL'

        Mock Register-RequestIdIndex { New-FreshRegistration }
        Mock Remove-RequestIdIndex { $true }
        Mock Get-IntuneManagedDevice { throw 'Graph is unavailable' }

        $response = Invoke-WipeIntakeRequest -Body $payload

        $response.StatusCode | Should -Be 502
        Should -Invoke Remove-RequestIdIndex -Times 1 -Exactly -ParameterFilter { $RequestId -eq 'REQ-GRAPH-FAIL' }

        # Replay: because the index was genuinely removed, Register-RequestIdIndex
        # sees a brand-new registration again (never permanently stranded), and the
        # full pipeline can now run to completion.
        Mock Register-RequestIdIndex { New-FreshRegistration }
        Mock Get-IntuneManagedDevice { New-FakeManagedDevice }
        Mock Lock-WipeDevice { New-AcquiredLease -RequestId 'REQ-GRAPH-FAIL' }
        Mock Save-WipeRequestState { @{} }

        $retryResponse = Invoke-WipeIntakeRequest -Body $payload

        $retryResponse.StatusCode | Should -Be 202
        (Get-ResponseBody $retryResponse).status | Should -Be 'Accepted'
        (Get-ResponseBody $retryResponse).requestId | Should -Be 'REQ-GRAPH-FAIL'
    }

    It 'fails closed (502) instead of a hollow 422 when persisting the Rejected outcome itself fails' {
        $payload = New-ValidWipePayload -RequestId 'REQ-REJECT-FAIL'

        Mock Register-RequestIdIndex { New-FreshRegistration }
        Mock Remove-RequestIdIndex { $true }
        Mock Get-IntuneManagedDevice { $null } # device not managed by Intune -> Rejected path
        Mock Save-WipeRequestState { throw 'Table Storage unavailable' }

        $response = Invoke-WipeIntakeRequest -Body $payload

        $response.StatusCode | Should -Be 502
        (Get-ResponseBody $response).error | Should -Match 'rejected request'
        Should -Invoke Save-WipeRequestState -Times 1 -Exactly
        Should -Invoke Remove-RequestIdIndex -Times 1 -Exactly -ParameterFilter { $RequestId -eq 'REQ-REJECT-FAIL' }
    }

    It 'cleans up the __RequestId index when acquiring the device lease throws' {
        $payload = New-ValidWipePayload -RequestId 'REQ-LEASE-EXCEPTION'

        Mock Register-RequestIdIndex { New-FreshRegistration }
        Mock Remove-RequestIdIndex { $true }
        Mock Get-IntuneManagedDevice { New-FakeManagedDevice }
        Mock Lock-WipeDevice { throw 'Table Storage timeout' }

        $response = Invoke-WipeIntakeRequest -Body $payload

        $response.StatusCode | Should -Be 500
        Should -Invoke Remove-RequestIdIndex -Times 1 -Exactly -ParameterFilter { $RequestId -eq 'REQ-LEASE-EXCEPTION' }
    }

    It 'cleans up the __RequestId index when another disposal request already holds the device lease (409)' {
        $payload = New-ValidWipePayload -RequestId 'REQ-LEASE-409'

        Mock Register-RequestIdIndex { New-FreshRegistration }
        Mock Remove-RequestIdIndex { $true }
        Mock Get-IntuneManagedDevice { New-FakeManagedDevice }
        Mock Lock-WipeDevice {
            [pscustomobject]@{
                Acquired        = $false
                ActiveRequestId = 'SOME-OTHER-REQUEST'
                ActivePlatform  = 'Windows'
                ExpiresAt       = (Get-Date).ToUniversalTime().AddHours(1).ToString('o')
            }
        }

        $response = Invoke-WipeIntakeRequest -Body $payload

        $response.StatusCode | Should -Be 409
        Should -Invoke Remove-RequestIdIndex -Times 1 -Exactly -ParameterFilter { $RequestId -eq 'REQ-LEASE-409' }
    }

    It 'releases the device lease AND cleans up the __RequestId index when the initial Accepted-state persist fails' {
        $payload = New-ValidWipePayload -RequestId 'REQ-STATE-PERSIST-FAIL'

        Mock Register-RequestIdIndex { New-FreshRegistration }
        Mock Remove-RequestIdIndex { $true }
        Mock Get-IntuneManagedDevice { New-FakeManagedDevice }
        Mock Lock-WipeDevice { New-AcquiredLease -RequestId 'REQ-STATE-PERSIST-FAIL' }
        Mock Unlock-WipeDevice { $true }
        Mock Save-WipeRequestState { throw 'Table Storage unavailable' }

        $response = Invoke-WipeIntakeRequest -Body $payload

        $response.StatusCode | Should -Be 500
        Should -Invoke Unlock-WipeDevice -Times 1 -Exactly
        Should -Invoke Remove-RequestIdIndex -Times 1 -Exactly -ParameterFilter { $RequestId -eq 'REQ-STATE-PERSIST-FAIL' }
    }

    It 'does not attempt any index cleanup on the ordinary success path' {
        $payload = New-ValidWipePayload -RequestId 'REQ-HAPPY-PATH'

        Mock Register-RequestIdIndex { New-FreshRegistration }
        Mock Remove-RequestIdIndex { $true }
        Mock Get-IntuneManagedDevice { New-FakeManagedDevice }
        Mock Lock-WipeDevice { New-AcquiredLease -RequestId 'REQ-HAPPY-PATH' }
        Mock Save-WipeRequestState { @{} }

        $response = Invoke-WipeIntakeRequest -Body $payload

        $response.StatusCode | Should -Be 202
        Should -Invoke Remove-RequestIdIndex -Times 0 -Exactly
    }
}
