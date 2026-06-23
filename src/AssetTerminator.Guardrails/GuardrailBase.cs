using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Guardrails;
using AssetTerminator.Core.Options;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Guardrails;

public abstract class GuardrailBase(IOptionsMonitor<GuardrailsOptions> options) : IWipeGuardrail
{
    public abstract string Id { get; }

    protected GuardrailOptions Options =>
        options.CurrentValue.Items.TryGetValue(Id, out var guardrailOptions)
            ? guardrailOptions
            : new GuardrailOptions();

    protected bool Mandatory => Options.Mandatory;

    protected bool Overridable => Options.Overridable;

    protected int? Threshold => Options.Threshold;

    protected IReadOnlyDictionary<string, string> Settings => Options.Settings;

    public abstract Task<GuardrailResult> EvaluateAsync(DeviceContext context, CancellationToken ct);

    protected GuardrailResult Pass(GuardrailSeverity severity = GuardrailSeverity.Info) =>
        new()
        {
            GuardrailId = Id,
            Passed = true,
            Severity = severity,
            Mandatory = Mandatory,
            Overridable = Overridable
        };

    protected GuardrailResult Fail(string reason, GuardrailSeverity severity = GuardrailSeverity.Blocking) =>
        GuardrailResult.Fail(Id, reason, Mandatory ? severity : GuardrailSeverity.Warning, Mandatory, Overridable);
}
