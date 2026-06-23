#requires -Version 7.0
<#
.SYNOPSIS
    Simulates a ServiceNow asset-decommission request against the Asset-Terminator
    PowerShell POC and (optionally) targets a REAL device in your Intune tenant.

.DESCRIPTION
    Mirrors what ServiceNow does:
      1. Builds the decommission/wipe DTO (requestId, deviceName, serialNumber, ...).
      2. POSTs it to the Intake Function App (/api/v1/wipe).
      3. Polls the status endpoint (/api/v1/decommission/{requestId}) until the
         request reaches a terminal state (Completed | Blocked | Failed) or times out.

    SAFETY: the wipe runs in DRY-RUN by default - the processor resolves the device
    and evaluates the guardrails but does NOT issue the destructive Graph wipe action.
    Pass -Execute to request a real wipe (you will be prompted to confirm).

    Use -ListDevices to browse managed devices in your tenant (via Microsoft Graph,
    using your current `az login` context) so you can copy a real deviceName/serial.

.PARAMETER ResourceGroup
    Resource group hosting the POC. Default: ASSET-TERMINATOR-POC-RG.

.PARAMETER IntakeApp
    Name of the Intake Function App. Default: attpoc-intake-dev.

.PARAMETER DeviceName
    Device display name (as known to Intune). At least one of DeviceName /
    SerialNumber / ManagedDeviceId is required (unless -ListDevices).

.PARAMETER SerialNumber
    Device serial number. ServiceNow typically sends this together with DeviceName.

.PARAMETER ManagedDeviceId
    Intune managedDevice id (GUID) - most precise selector if you already have it.

.PARAMETER TicketNumber
    ServiceNow ticket number (free text). Default: auto-generated INC.

.PARAMETER Requestor
    Requestor identity recorded in the audit trail.

.PARAMETER Execute
    Request a REAL wipe (dryRun = false). Without this switch the call is a dry-run.

.PARAMETER ListDevices
    List managed devices from Intune (Graph) and exit. Optionally filter with
    -DeviceName / -SerialNumber (client-side contains match).

.PARAMETER PollTimeoutSeconds
    Max seconds to poll for a terminal state. Default: 180.

.PARAMETER NoPoll
    Submit the request and return immediately without polling the status.

.EXAMPLE
    ./Invoke-ServiceNowWipe.ps1 -ListDevices

.EXAMPLE
    ./Invoke-ServiceNowWipe.ps1 -DeviceName 'LAPTOP-FIN-007' -SerialNumber '5CG1234XYZ'

.EXAMPLE
    ./Invoke-ServiceNowWipe.ps1 -ManagedDeviceId '00000000-0000-0000-0000-000000000000' -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ResourceGroup = 'ASSET-TERMINATOR-POC-RG',
    [string] $IntakeApp = 'attpoc-intake-dev',
    [string] $DeviceName,
    [string] $SerialNumber,
    [string] $ManagedDeviceId,
    [string] $TicketNumber,
    [string] $Requestor = 'service-desk@contoso.com',
    [switch] $Execute,
    [switch] $ListDevices,
    [int]    $PollTimeoutSeconds = 180,
    [switch] $NoPoll
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Text) Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn { param([string] $Text) Write-Host "    $Text" -ForegroundColor Yellow }

function Connect-IntuneGraph {
    # The az CLI first-party app is NOT authorized for Intune device scopes, so we
    # use the Microsoft Graph PowerShell SDK (pre-authorized first-party app) with an
    # interactive sign-in requesting the read scope only.
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw "Microsoft.Graph.Authentication module not found. Install with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext
    if (-not $ctx -or ($ctx.Scopes -notcontains 'DeviceManagementManagedDevices.Read.All')) {
        Write-Step "Signing in to Microsoft Graph (scope: DeviceManagementManagedDevices.Read.All)..."
        Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All' -NoWelcome | Out-Null
    }
}

# --- List devices mode ------------------------------------------------------
if ($ListDevices) {
    Connect-IntuneGraph
    Write-Step "Querying Intune managed devices via Microsoft Graph..."
    $select = 'id,deviceName,serialNumber,operatingSystem,managedDeviceOwnerType,complianceState,enrolledDateTime,lastSyncDateTime,userPrincipalName'
    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$select=$select&`$top=200"

    $devices = [System.Collections.Generic.List[object]]::new()
    while ($uri) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri
        foreach ($d in $resp.value) { $devices.Add([pscustomobject]$d) }
        $uri = $resp.'@odata.nextLink'
    }

    if ($DeviceName)   { $devices = $devices | Where-Object { $_.deviceName   -like "*$DeviceName*" } }
    if ($SerialNumber) { $devices = $devices | Where-Object { $_.serialNumber -like "*$SerialNumber*" } }

    Write-Ok "$($devices.Count) device(s) found."
    $devices |
        Sort-Object lastSyncDateTime -Descending |
        Select-Object deviceName, serialNumber, operatingSystem, complianceState,
                      @{ n = 'lastSync'; e = { $_.lastSyncDateTime } },
                      @{ n = 'enrolled'; e = { $_.enrolledDateTime } },
                      userPrincipalName, id |
        Format-Table -AutoSize
    return
}

# --- Validation -------------------------------------------------------------
if (-not $DeviceName -and -not $SerialNumber -and -not $ManagedDeviceId) {
    throw "Specify at least one of -DeviceName, -SerialNumber or -ManagedDeviceId (or use -ListDevices to browse)."
}

$dryRun = -not $Execute
if ($Execute) {
    $target = @($DeviceName, $SerialNumber, $ManagedDeviceId | Where-Object { $_ }) -join ' / '
    if (-not $PSCmdlet.ShouldProcess($target, "REAL Intune WIPE (irreversible)")) {
        Write-Warn "Aborted by user. No request submitted."
        return
    }
}

if (-not $TicketNumber) { $TicketNumber = "INC{0:D7}" -f (Get-Random -Minimum 1 -Maximum 9999999) }
$requestId = "SNOW-$TicketNumber-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"

# --- Build the ServiceNow-style payload ------------------------------------
$payload = [ordered]@{
    requestId        = $requestId
    ticketNumber     = $TicketNumber
    requestor        = $Requestor
    timestamp        = [DateTime]::UtcNow.ToString('o')
    requestedActions = @('delete-Intune', 'wipe')
    dryRun           = $dryRun
}
if ($DeviceName)      { $payload.deviceName      = $DeviceName }
if ($SerialNumber)    { $payload.serialNumber    = $SerialNumber }
if ($ManagedDeviceId) { $payload.managedDeviceId = $ManagedDeviceId }

# --- Resolve the intake endpoint + key -------------------------------------
Write-Step "Resolving Intake Function App key ($IntakeApp)..."
$key = az functionapp keys list -g $ResourceGroup -n $IntakeApp --query functionKeys.default -o tsv 2>$null
if (-not $key) { throw "Could not read the function key for '$IntakeApp' in '$ResourceGroup'. Check az login / names." }

$baseUrl = "https://$IntakeApp.azurewebsites.net"
$headers = @{ 'x-functions-key' = $key }

Write-Step ("Submitting wipe request (dryRun=$dryRun)")
Write-Host ($payload | ConvertTo-Json -Depth 6)

$resp = Invoke-RestMethod -Method Post -Uri "$baseUrl/api/v1/wipe" `
    -Headers $headers -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Depth 6)

Write-Ok "HTTP response:"
$resp | ConvertTo-Json -Depth 6 | Write-Host

if ($resp.status -eq 'AlreadyAccepted') {
    Write-Warn "Duplicate requestId - the intake returned the existing tracking record (idempotency)."
}

if ($NoPoll) {
    Write-Step "Done (no polling requested). Track with:"
    Write-Host "  Invoke-RestMethod -Uri '$baseUrl/api/v1/decommission/$requestId' -Headers @{ 'x-functions-key' = '<key>' }"
    return
}

# --- Poll the status endpoint ----------------------------------------------
Write-Step "Polling status (timeout ${PollTimeoutSeconds}s)..."
$deadline = (Get-Date).AddSeconds($PollTimeoutSeconds)
$terminal = @('Completed', 'Blocked', 'Failed')
$lastStatus = $null

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    try {
        $state = Invoke-RestMethod -Method Get -Uri "$baseUrl/api/v1/decommission/$requestId" -Headers $headers
    }
    catch {
        Write-Warn "Status not available yet ($($_.Exception.Message))"
        continue
    }

    if ($state.overallStatus -ne $lastStatus) {
        $lastStatus = $state.overallStatus
        $detail = if ($state.detail) { " - $($state.detail)" } else { '' }
        Write-Host ("    [{0:HH:mm:ss}] {1}{2}" -f (Get-Date), $state.overallStatus, $detail)
    }

    if ($state.overallStatus -in $terminal) {
        Write-Host ""
        switch ($state.overallStatus) {
            'Completed' { Write-Ok   "WIPE COMPLETED ($(if ($state.dryRun) { 'dry-run / simulated' } else { 'REAL' }))." }
            'Blocked'   { Write-Warn "BLOCKED by guardrails - no wipe performed." }
            'Failed'    { Write-Warn "FAILED - $($state.detail)" }
        }
        Write-Step "Final state + history:"
        $state | ConvertTo-Json -Depth 8 | Write-Host
        return
    }
}

Write-Warn "Timed out after ${PollTimeoutSeconds}s; last status: $lastStatus. Re-query later:"
Write-Host "  Invoke-RestMethod -Uri '$baseUrl/api/v1/decommission/$requestId' -Headers @{ 'x-functions-key' = '<key>' }"
