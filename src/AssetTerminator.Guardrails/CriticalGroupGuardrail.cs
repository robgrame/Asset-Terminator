using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Guardrails;
using AssetTerminator.Core.Options;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Guardrails;

public sealed class CriticalGroupGuardrail(IOptionsMonitor<GuardrailsOptions> options) : GuardrailBase(options)
{
    public const string GuardrailId = "critical-group";

    public override string Id => GuardrailId;

    public override Task<GuardrailResult> EvaluateAsync(DeviceContext context, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();

        var blockedGroups = GetBlockedGroups();
        var matchedGroup = context.GroupMemberships.FirstOrDefault(blockedGroups.Contains);

        return Task.FromResult(matchedGroup is null
            ? Pass()
            : Fail($"Device belongs to blocked group '{matchedGroup}'."));
    }

    private HashSet<string> GetBlockedGroups()
    {
        if (!Settings.TryGetValue("BlockedGroups", out var blockedGroups) || string.IsNullOrWhiteSpace(blockedGroups))
        {
            return [];
        }

        return blockedGroups
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
    }
}
