# Sla.psm1  (nested in AT.Infrastructure)
# SLA deadline and state computation. Parity with
# AssetTerminator.Infrastructure.Sla.SlaCalculator + Core.Options.SlaOptions.
#
# Config is a hashtable keyed by category, each with:
#   MaxCompletionHours (double), AtRiskThreshold (0..1), PollingMinutes, MaxRetries
# Defaults mirror the .NET SlaCategoryOptions (7 days, 0.8 at-risk).

Set-StrictMode -Version Latest

function Get-DefaultSlaConfig {
    <#
        .SYNOPSIS
            Returns the default per-category SLA configuration (parity with .NET defaults).
    #>
    [CmdletBinding()]
    param()
    @{
        Standard = @{ MaxCompletionHours = 168.0; AtRiskThreshold = 0.8; PollingMinutes = 30; MaxRetries = 10 }
        Vip      = @{ MaxCompletionHours = 48.0;  AtRiskThreshold = 0.8; PollingMinutes = 15; MaxRetries = 10 }
        Critical = @{ MaxCompletionHours = 24.0;  AtRiskThreshold = 0.75; PollingMinutes = 10; MaxRetries = 10 }
    }
}

function Resolve-SlaCategory {
    param($Config, [string] $Category)
    if ($Config -and $Config.ContainsKey($Category)) { return $Config[$Category] }
    return @{ MaxCompletionHours = 168.0; AtRiskThreshold = 0.8; PollingMinutes = 30; MaxRetries = 10 }
}

function Get-SlaDueAt {
    <#
        .SYNOPSIS
            Computes the SLA deadline (UTC) for a category. Parity with ComputeDueAt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Category,
        [datetime] $CreatedAtUtc = ([datetime]::UtcNow),
        [hashtable] $Config = (Get-DefaultSlaConfig)
    )
    $cfg = Resolve-SlaCategory $Config $Category
    return $CreatedAtUtc.AddHours($cfg.MaxCompletionHours)
}

function Get-SlaState {
    <#
        .SYNOPSIS
            Evaluates SLA state (WithinSla | AtRisk | Breached). Parity with Evaluate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][datetime] $CreatedAtUtc,
        [datetime] $NowUtc = ([datetime]::UtcNow),
        [hashtable] $Config = (Get-DefaultSlaConfig)
    )
    $cfg = Resolve-SlaCategory $Config $Category
    $elapsedHours = ($NowUtc - $CreatedAtUtc).TotalHours
    if ($elapsedHours -ge $cfg.MaxCompletionHours) { return 'Breached' }
    if ($elapsedHours -ge ($cfg.MaxCompletionHours * $cfg.AtRiskThreshold)) { return 'AtRisk' }
    return 'WithinSla'
}

Export-ModuleMember -Function Get-DefaultSlaConfig, Get-SlaDueAt, Get-SlaState
