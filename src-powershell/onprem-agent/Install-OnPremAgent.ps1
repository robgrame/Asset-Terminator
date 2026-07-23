<#
    Install-OnPremAgent.ps1 — registers the Asset-Terminator on-prem agent as a SYSTEM
    scheduled task. The task launches run-agent.ps1 on a recurring interval; each run drains
    the on-prem queue for a bounded window and exits, so long device tools are never killed at
    shell teardown (the task simply re-launches on the next tick).

    Must be run elevated. Parity host for AssetTerminator.OnPremAgent (BackgroundService).
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'AssetTerminator-OnPremAgent',
    [int]    $IntervalMinutes = 60,
    [string] $AgentRoot = $PSScriptRoot,
    [string] $PwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
)

$ErrorActionPreference = 'Stop'

if (-not $PwshPath) { throw 'PowerShell 7 (pwsh) not found on PATH; install it or pass -PwshPath.' }
$runScript = Join-Path $AgentRoot 'run-agent.ps1'
if (-not (Test-Path $runScript)) { throw "run-agent.ps1 not found under $AgentRoot." }

$maxRuntime = [Math]::Max(60, ($IntervalMinutes * 60) - 300)   # finish ~5 min before the next tick
$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runScript`" -MaxRuntimeSeconds $maxRuntime"

$action = New-ScheduledTaskAction -Execute $PwshPath -Argument $arguments -WorkingDirectory $AgentRoot
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes ($IntervalMinutes + 5)) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $taskSettings -Description 'Asset-Terminator on-prem cleanup agent (AD/ConfigMgr/DeviceActions).' -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName' running every $IntervalMinutes min as SYSTEM."
Write-Host "  Script : $runScript"
Write-Host "  Max run: $maxRuntime s per launch"
Write-Host "Ensure agent.settings.psd1 exists next to run-agent.ps1 (copy from agent.settings.psd1.example)."
