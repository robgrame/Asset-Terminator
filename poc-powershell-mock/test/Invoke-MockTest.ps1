<#
.SYNOPSIS
    End-to-end test for the Asset-Terminator PowerShell mock: issues a wipe and
    then queries the live request status.

.DESCRIPTION
    1. POST  /api/v1/wipe          with a sample ServiceNow decommission message.
    2. GET   /api/v1/wipe/status   for the same device, showing the live wipe /
       Autopilot status derived from Microsoft Graph.

    Works against a local host (func start, no key) or a deployed Function App
    (pass -FunctionKey). The key is sent as the x-functions-key header.

.PARAMETER BaseUrl
    Function base URL. Local default: http://localhost:7071.
    Azure example: https://attmock-func-dev.azurewebsites.net

.PARAMETER FunctionKey
    Function/host key for a deployed app (omit for a local host).

.PARAMETER SamplePath
    Path to the request JSON. Defaults to samples/request-windows.json.

.PARAMETER DryRun
    Force dryRun=true (safe: evaluates everything, calls nothing destructive).

.PARAMETER Execute
    Force dryRun=false (really deletes from Autopilot and issues the wipe).

.PARAMETER SkipStatus
    Only send the wipe, skip the status query.

.EXAMPLE
    # Local host, safe dry-run against the Windows sample
    ./Invoke-MockTest.ps1 -DryRun

.EXAMPLE
    # Deployed app, real execution
    ./Invoke-MockTest.ps1 -BaseUrl https://attmock-func-dev.azurewebsites.net `
        -FunctionKey <key> -Execute
#>
[CmdletBinding()]
param(
    [string] $BaseUrl = 'http://localhost:7071',
    [string] $FunctionKey,
    [string] $SamplePath = (Join-Path $PSScriptRoot '..\samples\request-windows.json'),
    [switch] $DryRun,
    [switch] $Execute,
    [switch] $SkipStatus
)

$ErrorActionPreference = 'Stop'

if ($DryRun -and $Execute) {
    throw 'Specify only one of -DryRun or -Execute.'
}

$BaseUrl = $BaseUrl.TrimEnd('/')
$headers = @{}
if ($FunctionKey) { $headers['x-functions-key'] = $FunctionKey }

# --- Load and (optionally) tweak the sample message -------------------------
if (-not (Test-Path $SamplePath)) { throw "Sample file not found: $SamplePath" }
$request = Get-Content $SamplePath -Raw | ConvertFrom-Json

if ($DryRun)  { $request | Add-Member -NotePropertyName dryRun -NotePropertyValue $true  -Force }
if ($Execute) { $request | Add-Member -NotePropertyName dryRun -NotePropertyValue $false -Force }

$body = $request | ConvertTo-Json -Depth 8

Write-Host "==> POST $BaseUrl/api/v1/wipe" -ForegroundColor Cyan
Write-Host "    device=$($request.deviceName) serial=$($request.serialNumber) os=$($request.operatingSystem) dryRun=$($request.dryRun)" -ForegroundColor DarkGray

function Invoke-Json {
    param([string] $Method, [string] $Uri, [string] $Body)
    try {
        if ($Body) {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType 'application/json' -Body $Body
        }
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $content = $sr.ReadToEnd()
            Write-Host "    HTTP error: $([int]$resp.StatusCode)" -ForegroundColor Red
            if ($content) { Write-Host $content -ForegroundColor Red }
        }
        else {
            Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
        }
        return $null
    }
}

$wipeResult = Invoke-Json -Method Post -Uri "$BaseUrl/api/v1/wipe" -Body $body
if ($wipeResult) {
    Write-Host "--- wipe response ---" -ForegroundColor Green
    $wipeResult | ConvertTo-Json -Depth 8 | Write-Host
}

if ($SkipStatus) { return }

# --- Build the status query from whatever identifiers we have ----------------
$statusParams = @{}
if ($wipeResult.device.id)          { $statusParams['managedDeviceId'] = $wipeResult.device.id }
elseif ($request.managedDeviceId)   { $statusParams['managedDeviceId'] = $request.managedDeviceId }
if ($request.serialNumber)          { $statusParams['serialNumber']    = $request.serialNumber }
if ($request.deviceName)            { $statusParams['deviceName']      = $request.deviceName }
if ($request.operatingSystem)       { $statusParams['operatingSystem'] = $request.operatingSystem }

if ($statusParams.Count -eq 0) {
    Write-Host "==> Skipping status: no identifier available." -ForegroundColor Yellow
    return
}

$query = ($statusParams.GetEnumerator() | ForEach-Object {
    '{0}={1}' -f $_.Key, [Uri]::EscapeDataString([string]$_.Value)
}) -join '&'

$statusUri = "$BaseUrl/api/v1/wipe/status?$query"
Write-Host ""
Write-Host "==> GET $statusUri" -ForegroundColor Cyan

$statusResult = Invoke-Json -Method Get -Uri $statusUri
if ($statusResult) {
    Write-Host "--- status response ---" -ForegroundColor Green
    $statusResult | ConvertTo-Json -Depth 8 | Write-Host
    Write-Host ""
    Write-Host "overallStatus: $($statusResult.overallStatus)" -ForegroundColor Yellow
}
