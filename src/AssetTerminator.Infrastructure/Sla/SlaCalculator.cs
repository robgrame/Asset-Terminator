using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Options;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Infrastructure.Sla;

/// <summary>
/// Computes deadlines and SLA state from the per-category configuration.
/// </summary>
public sealed class SlaCalculator : ISlaCalculator
{
    private readonly IOptionsMonitor<SlaOptions> _options;

    public SlaCalculator(IOptionsMonitor<SlaOptions> options)
    {
        _options = options;
    }

    public DateTimeOffset ComputeDueAt(AssetCategory category, DateTimeOffset createdAtUtc) =>
        createdAtUtc + _options.CurrentValue.For(category).MaxCompletionTime;

    public SlaState Evaluate(AssetCategory category, DateTimeOffset createdAtUtc, DateTimeOffset nowUtc)
    {
        var cfg = _options.CurrentValue.For(category);
        var elapsed = nowUtc - createdAtUtc;
        if (elapsed >= cfg.MaxCompletionTime)
            return SlaState.Breached;
        if (elapsed >= cfg.MaxCompletionTime * cfg.AtRiskThreshold)
            return SlaState.AtRisk;
        return SlaState.WithinSla;
    }
}
