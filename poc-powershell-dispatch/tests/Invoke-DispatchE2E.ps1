#Requires -Version 7.6

<#
.SYNOPSIS
    Runs an end-to-end test against a deployed Asset-Terminator Dispatch API.

.DESCRIPTION
    Resolves the Function App host name and default host key with Azure CLI,
    submits a unique wipe request, then polls the status endpoint until the
    request reaches a terminal state. The test is a dry run unless -Real is
    explicitly specified. BaseUri and FunctionKey can be supplied directly
    instead of resolving the deployment through Azure CLI.

.EXAMPLE
    ./tests/Invoke-DispatchE2E.ps1 `
        -ResourceGroup DeviceLifecycleAction `
        -FunctionAppName attdisp02-func-api-dev `
        -Subscription <subscription-id> `
        -SerialNumber 5CG1234ABC
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'Azure')] [string] $ResourceGroup,
    [Parameter(Mandatory, ParameterSetName = 'Azure')] [string] $FunctionAppName,
    [Parameter(ParameterSetName = 'Azure')] [string] $Subscription,

    [Parameter(Mandatory, ParameterSetName = 'Direct')] [uri] $BaseUri,
    [Parameter(Mandatory, ParameterSetName = 'Direct')] [string] $FunctionKey,

    [Parameter(Mandatory)] [string] $SerialNumber,
    [string] $DeviceName,
    [string] $ManagedDeviceId,
    [string] $Imei,
    [ValidateSet('Windows', 'Apple', 'Android', 'Mobile')]
    [string] $OperatingSystem = 'Windows',
    [ValidateSet('Retirement', 'Sale', 'Disposal', 'LostStolen')]
    [string] $Scenario = 'Disposal',
    [string] $MdmServerId,
    [string] $CallbackUrl,

    [string] $RequestId,
    [ValidateSet('Completed', 'PartiallyCompleted', 'Failed', 'Rejected', 'DispatchFailed')]
    [string[]] $ExpectedTerminalStatus = @('Completed'),
    [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 1800,
    [ValidateRange(1, 300)] [int] $PollIntervalSeconds = 10,
    [switch] $Real
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzTsv {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $output = & az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: $($output -join [Environment]::NewLine)"
    }
    return ([string]($output -join '')).Trim()
}

function ConvertTo-TestBoolean {
    param(
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)] [string] $FieldName
    )

    if ($Value -is [bool]) { return $Value }

    $parsed = $false
    if ([bool]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }

    throw "$FieldName must be a boolean, received '$Value'."
}

$baseUriValue = if ($PSCmdlet.ParameterSetName -eq 'Azure') {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI was not found. Install it and run az login before the E2E test.'
    }

    $subscriptionId = if ([string]::IsNullOrWhiteSpace($Subscription)) {
        Invoke-AzTsv -Arguments @('account', 'show', '--query', 'id', '--output', 'tsv')
    }
    else {
        $Subscription
    }

    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw 'Unable to resolve an Azure subscription. Run az login or specify -Subscription.'
    }

    $azScope = @('--subscription', $subscriptionId)
    $hostName = Invoke-AzTsv -Arguments (@(
        'functionapp', 'show',
        '--resource-group', $ResourceGroup,
        '--name', $FunctionAppName,
        '--query', 'defaultHostName',
        '--output', 'tsv'
    ) + $azScope)

    $FunctionKey = Invoke-AzTsv -Arguments (@(
        'functionapp', 'keys', 'list',
        '--resource-group', $ResourceGroup,
        '--name', $FunctionAppName,
        '--query', 'functionKeys.default',
        '--output', 'tsv'
    ) + $azScope)

    if ([string]::IsNullOrWhiteSpace($hostName)) {
        throw "Function App '$FunctionAppName' did not return a default host name."
    }
    if ([string]::IsNullOrWhiteSpace($FunctionKey)) {
        throw "Function App '$FunctionAppName' did not return its default host key."
    }

    "https://$($hostName.TrimEnd('/'))"
}
else {
    $BaseUri.AbsoluteUri.TrimEnd('/')
}

if ([string]::IsNullOrWhiteSpace($RequestId)) {
    $RequestId = 'E2E-{0}-{1}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
}

$expectedDryRun = -not $Real.IsPresent
$payload = [ordered]@{
    requestId       = $RequestId
    serialNumber    = $SerialNumber
    operatingSystem = $OperatingSystem
    scenario        = $Scenario
    userConfirmed   = $true
    dryRun          = $expectedDryRun
}

foreach ($optionalValue in @(
        @{ Name = 'deviceName'; Value = $DeviceName }
        @{ Name = 'managedDeviceId'; Value = $ManagedDeviceId }
        @{ Name = 'imei'; Value = $Imei }
        @{ Name = 'mdmServerId'; Value = $MdmServerId }
        @{ Name = 'callbackUrl'; Value = $CallbackUrl }
    )) {
    if (-not [string]::IsNullOrWhiteSpace([string]$optionalValue.Value)) {
        $payload[$optionalValue.Name] = $optionalValue.Value
    }
}

$headers = @{ 'x-functions-key' = $FunctionKey }

Write-Host "POST $baseUriValue/api/v1/wipe (requestId=$RequestId, dryRun=$expectedDryRun)" -ForegroundColor Cyan
$response = Invoke-WebRequest `
    -Uri "$baseUriValue/api/v1/wipe" `
    -Method Post `
    -Headers $headers `
    -ContentType 'application/json' `
    -Body ($payload | ConvertTo-Json -Depth 8)

if ([int]$response.StatusCode -ne 202) {
    throw "Expected HTTP 202 from WipeIntake, received $($response.StatusCode): $($response.Content)"
}

$accepted = $response.Content | ConvertFrom-Json
if ([string]$accepted.requestId -ne $RequestId) {
    throw "WipeIntake returned requestId '$($accepted.requestId)' instead of '$RequestId'."
}
if ([string]$accepted.status -ne 'Queued') {
    throw "WipeIntake returned status '$($accepted.status)' instead of 'Queued'."
}
$acceptedDryRun = ConvertTo-TestBoolean -Value $accepted.dryRun -FieldName 'WipeIntake dryRun'
if ($acceptedDryRun -ne $expectedDryRun) {
    throw "WipeIntake returned dryRun='$acceptedDryRun', expected '$expectedDryRun'."
}

$terminalStates = @('Completed', 'PartiallyCompleted', 'Failed', 'Rejected', 'DispatchFailed')
$deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
$encodedRequestId = [uri]::EscapeDataString($RequestId)
$statusUri = "$baseUriValue/api/v1/wipe/status?requestId=$encodedRequestId"
$lastStatus = 'Queued'
$state = $null

do {
    Start-Sleep -Seconds $PollIntervalSeconds
    $state = Invoke-RestMethod -Uri $statusUri -Method Get -Headers $headers

    if ([string]$state.requestId -ne $RequestId) {
        throw "GetStatus returned requestId '$($state.requestId)' instead of '$RequestId'."
    }

    $lastStatus = [string]$state.status
    Write-Host ("[{0:HH:mm:ss}] status={1}" -f (Get-Date), $lastStatus)

    if ($terminalStates -contains $lastStatus) { break }
} while ((Get-Date).ToUniversalTime() -lt $deadline)

if ($terminalStates -notcontains $lastStatus) {
    throw "E2E test timed out after $TimeoutSeconds seconds (last status: $lastStatus)."
}

Write-Host ($state | ConvertTo-Json -Depth 12)

if ($ExpectedTerminalStatus -notcontains $lastStatus) {
    throw "E2E test reached '$lastStatus'; expected: $($ExpectedTerminalStatus -join ', '). Error: $($state.errorMessage)"
}

if ($lastStatus -in @('Completed', 'PartiallyCompleted')) {
    if ($null -eq $state.result -or -not ($state.result.PSObject.Properties.Name -contains 'dryRun')) {
        throw 'The terminal result does not contain the expected dryRun evidence.'
    }

    $resultDryRun = ConvertTo-TestBoolean -Value $state.result.dryRun -FieldName 'Terminal result dryRun'
    if ($resultDryRun -ne $expectedDryRun) {
        throw "Terminal result reports dryRun='$resultDryRun', but the request specified '$expectedDryRun'."
    }
}

Write-Host "E2E test passed: request '$RequestId' reached '$lastStatus'." -ForegroundColor Green
