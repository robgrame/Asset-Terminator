using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Guardrails;
using AssetTerminator.Core.Options;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Guardrails;

public sealed class InactivityGuardrail(IOptionsMonitor<GuardrailsOptions> options) : GuardrailBase(options)
{
    public const string GuardrailId = "inactivity";
    private const int DefaultThresholdDays = 30;

    public override string Id => GuardrailId;

    public override Task<GuardrailResult> EvaluateAsync(DeviceContext context, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();

        if (context.LastActivityUtc is null)
        {
            return Task.FromResult(Fail("Last activity is unknown; failing closed."));
        }

        var thresholdDays = Threshold ?? DefaultThresholdDays;
        var cutoff = DateTimeOffset.UtcNow.AddDays(-thresholdDays);

        return Task.FromResult(context.LastActivityUtc < cutoff
            ? Pass()
            : Fail($"Device was active too recently. Last activity {context.LastActivityUtc:O} is within the {thresholdDays}-day inactivity threshold."));
    }
}
