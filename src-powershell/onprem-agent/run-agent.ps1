<#
    run-agent.ps1 — Asset-Terminator on-prem agent entry point.

    Hosted as a SYSTEM scheduled task inside the customer network (line-of-sight to the DC
    and the SCCM AdminService). Pulls ActionDispatch messages from the on-prem Service Bus
    queue (peek-lock), executes AD / ConfigMgr / DeviceActions and writes the outcome back
    to the shared SQL state store + WORM audit.

    Parity with AssetTerminator.OnPremAgent (Program + Worker). Runs for a bounded duration
    (the scheduled task re-launches it on schedule), so long-running device tools do not get
    killed at shell teardown — see the operational notes in README.md.
#>
[CmdletBinding()]
param(
    [string] $SettingsPath = (Join-Path $PSScriptRoot 'agent.settings.psd1'),
    [int]    $MaxRuntimeSeconds = 3300,   # ~55 min; stay under a hourly schedule
    [int]    $MaxMessages = 0,            # 0 = unbounded within the runtime window
    [int]    $ReceiveTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Module discovery: app-local Modules first, then the repo modules (source of truth). ---
$appModules = Join-Path $PSScriptRoot 'Modules'
$repoModules = Join-Path $PSScriptRoot '..' 'modules'
foreach ($dir in @($appModules, $repoModules)) {
    if ((Test-Path $dir) -and (($env:PSModulePath -split [IO.Path]::PathSeparator) -notcontains $dir)) {
        $env:PSModulePath = $dir + [IO.Path]::PathSeparator + $env:PSModulePath
    }
}

Import-Module 'AT.Common' -Force
Import-Module 'AT.Core' -Force
Import-Module 'AT.Infrastructure' -Force
Import-Module 'AT.Providers.ActiveDirectory' -Force
Import-Module 'AT.Providers.ConfigMgr' -Force
Import-Module 'AT.Providers.DeviceActions' -Force
Import-Module 'AT.Agent' -Force
Import-Module 'AT.ServiceBusReceiver' -Force

# --- Settings ---
if (-not (Test-Path $SettingsPath)) {
    throw "Agent settings file not found: $SettingsPath (copy agent.settings.psd1.example)."
}
$settings = Import-PowerShellDataFile -Path $SettingsPath

# Propagate the infra env vars consumed by AT.Infrastructure (SQL / Service Bus / Audit).
foreach ($kv in $settings.Environment.GetEnumerator()) {
    Set-Item -Path "Env:$($kv.Key)" -Value ([string]$kv.Value)
}

$namespace = $settings.ServiceBus.Namespace
$queue = $settings.ServiceBus.OnPremQueue
$sasToken = [string]$settings.ServiceBus.SasToken

# Build the provider config object consumed by AT.Agent.
$sccmCred = $null
if ($settings.ConfigMgr.CredentialXmlPath -and (Test-Path $settings.ConfigMgr.CredentialXmlPath)) {
    # DPAPI-protected credential exported with: Get-Credential | Export-Clixml <path>
    # (decryptable only by the same account/machine that created it — i.e. the SYSTEM task).
    $sccmCred = Import-Clixml -Path $settings.ConfigMgr.CredentialXmlPath
}
$config = [pscustomobject]@{
    DryRun         = [bool]$settings.DryRun
    AdSearchRoot   = [string]$settings.ActiveDirectory.SearchRoot
    SccmBaseUrl    = [string]$settings.ConfigMgr.AdminServiceBaseUrl
    SccmCredential = $sccmCred
    DeviceActions  = $settings.DeviceActions
}

Write-AtLog -Message "On-prem agent starting" -Properties @{
    queue = $queue; namespace = $namespace; dryRun = $config.DryRun; maxRuntimeSeconds = $MaxRuntimeSeconds
}

$deadline = (Get-Date).AddSeconds($MaxRuntimeSeconds)
$processed = 0

while ((Get-Date) -lt $deadline) {
    if ($MaxMessages -gt 0 -and $processed -ge $MaxMessages) { break }

    $message = $null
    try {
        $message = Receive-ServiceBusMessage -Namespace $namespace -Queue $queue `
            -TimeoutSeconds $ReceiveTimeoutSeconds -SasToken $sasToken
    }
    catch {
        Write-AtLog -Level 'Error' -Message "Receive failed: $($_.Exception.Message)"
        Start-Sleep -Seconds 5
        continue
    }
    if ($null -eq $message) { continue }   # queue empty within the timeout window

    $dispatch = $null
    try {
        $dispatch = ConvertFrom-ActionDispatchMessage -Json $message.Body
    }
    catch {
        # Un-parseable: it will never succeed on redelivery — complete + log (drop).
        Write-AtLog -Level 'Error' -Message "Malformed message, dropping: $($_.Exception.Message)"
        try { Complete-ServiceBusMessage -Message $message -Namespace $namespace -Queue $queue -SasToken $sasToken } catch { }
        continue
    }

    try {
        $outcome = Invoke-OnPremAction -Message $dispatch -Config $config
        Complete-ServiceBusMessage -Message $message -Namespace $namespace -Queue $queue -SasToken $sasToken
        $processed++
        Write-AtLog -Message "Message completed" -Properties @{
            requestId = $outcome.RequestId; target = $outcome.Target; status = $outcome.Status
        }
    }
    catch {
        # Transient / unexpected failure: abandon so Service Bus redelivers (auto-DLQ after max delivery count).
        Write-AtLog -Level 'Error' -Message "Processing failed, abandoning for retry: $($_.Exception.Message)" `
            -Properties @{ requestId = $dispatch.RequestId; target = $dispatch.Target }
        try { Suspend-ServiceBusMessage -Message $message -Namespace $namespace -Queue $queue -SasToken $sasToken } catch { }
    }
}

Write-AtLog -Message "On-prem agent stopping" -Properties @{ processed = $processed }
