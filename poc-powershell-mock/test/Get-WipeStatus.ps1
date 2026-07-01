<#
.SYNOPSIS
    Queries the live request status from the Asset-Terminator PowerShell mock.

.DESCRIPTION
    Calls GET /api/v1/wipe/status, which derives the status live from Microsoft
    Graph (Intune wipe progress + Autopilot removal). No wipe is issued.

    Works against a local host (func start, no key) or a deployed Function App
    (pass -FunctionKey; sent as the x-functions-key header).

    Pass at least one identifier. Use -Watch to poll until the wipe reaches a
    terminal state (WipeCompleted / WipeCompletedOrRemoved / WipeFailed).

.PARAMETER BaseUrl
    Function base URL. Local default: http://localhost:7071.

.PARAMETER FunctionKey
    Function/host key for a deployed app (omit for a local host).

.PARAMETER ManagedDeviceId
    Intune managed device id (most precise identifier).

.PARAMETER DeviceName
    Device name.

.PARAMETER SerialNumber
    Serial number (also used for the Autopilot presence check).

.PARAMETER OperatingSystem
    Windows | Mac | Mobile. Enables the Autopilot check for Windows.

.PARAMETER Watch
    Poll repeatedly until a terminal state is reached (or -MaxPolls is hit).

.PARAMETER IntervalSeconds
    Seconds between polls when -Watch is used (default 30).

.PARAMETER MaxPolls
    Maximum number of polls when -Watch is used (default 20).

.EXAMPLE
    ./Get-WipeStatus.ps1 -SerialNumber PF3ABCDE -OperatingSystem Windows

.EXAMPLE
    # Poll a deployed app until the wipe finishes
    ./Get-WipeStatus.ps1 -BaseUrl https://attmock-func-dev.azurewebsites.net `
        -FunctionKey <key> -ManagedDeviceId <id> -Watch
#>
[CmdletBinding()]
param(
    [string] $BaseUrl = 'http://localhost:7071',
    [string] $FunctionKey,

    [string] $ManagedDeviceId,
    [string] $DeviceName,
    [string] $SerialNumber,
    [ValidateSet('Windows', 'Mac', 'Mobile')]
    [string] $OperatingSystem,

    [switch] $Watch,
    [int] $IntervalSeconds = 30,
    [int] $MaxPolls = 20
)

$ErrorActionPreference = 'Stop'

if (-not $ManagedDeviceId -and -not $DeviceName -and -not $SerialNumber) {
    throw 'Provide at least one of -ManagedDeviceId, -DeviceName or -SerialNumber.'
}

$BaseUrl = $BaseUrl.TrimEnd('/')
$headers = @{}
if ($FunctionKey) { $headers['x-functions-key'] = $FunctionKey }

# --- Build the query string from the supplied identifiers -------------------
$params = @{}
if ($ManagedDeviceId) { $params['managedDeviceId'] = $ManagedDeviceId }
if ($DeviceName)      { $params['deviceName']      = $DeviceName }
if ($SerialNumber)    { $params['serialNumber']    = $SerialNumber }
if ($OperatingSystem) { $params['operatingSystem'] = $OperatingSystem }

$query = ($params.GetEnumerator() | ForEach-Object {
    '{0}={1}' -f $_.Key, [Uri]::EscapeDataString([string]$_.Value)
}) -join '&'
$uri = "$BaseUrl/api/v1/wipe/status?$query"

$terminalStates = @('WipeCompleted', 'WipeCompletedOrRemoved', 'WipeFailed')

function Get-Status {
    try {
        return Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $content = $sr.ReadToEnd()
            Write-Host "HTTP error: $([int]$resp.StatusCode)" -ForegroundColor Red
            if ($content) { Write-Host $content -ForegroundColor Red }
        }
        else {
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        }
        return $null
    }
}

$poll = 0
while ($true) {
    $poll++
    Write-Host "==> GET $uri" -ForegroundColor Cyan
    $status = Get-Status
    if (-not $status) { return }

    $status | ConvertTo-Json -Depth 8 | Write-Host
    Write-Host "overallStatus: $($status.overallStatus)" -ForegroundColor Yellow

    if (-not $Watch) { return $status }

    if ($terminalStates -contains $status.overallStatus) {
        Write-Host "Reached terminal state: $($status.overallStatus)." -ForegroundColor Green
        return $status
    }

    if ($poll -ge $MaxPolls) {
        Write-Host "Stopped after $MaxPolls polls (still $($status.overallStatus))." -ForegroundColor Yellow
        return $status
    }

    Write-Host "    not terminal yet; waiting $IntervalSeconds s (poll $poll/$MaxPolls)..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $IntervalSeconds
}
