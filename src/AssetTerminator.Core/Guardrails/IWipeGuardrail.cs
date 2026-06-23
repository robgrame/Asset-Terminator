using AssetTerminator.Core.Domain;

namespace AssetTerminator.Core.Guardrails;

/// <summary>
/// Outcome of evaluating a single guardrail against a <see cref="DeviceContext"/>.
/// </summary>
public sealed class GuardrailResult
{
    public required string GuardrailId { get; init; }
    public bool Passed { get; init; }
    public GuardrailSeverity Severity { get; init; }
    public string? Reason { get; init; }

    /// <summary>
    /// True when this guardrail is mandatory (a failure blocks the wipe). When false,
    /// a failure is recorded as a warning but does not block.
    /// </summary>
    public bool Mandatory { get; init; }

    /// <summary>True when this guardrail's block may be removed via approved override.</summary>
    public bool Overridable { get; init; }

    public static GuardrailResult Pass(string id, GuardrailSeverity severity = GuardrailSeverity.Info) =>
        new() { GuardrailId = id, Passed = true, Severity = severity };

    public static GuardrailResult Fail(string id, string reason, GuardrailSeverity severity,
        bool mandatory, bool overridable) =>
        new()
        {
            GuardrailId = id,
            Passed = false,
            Reason = reason,
            Severity = severity,
            Mandatory = mandatory,
            Overridable = overridable
        };
}

/// <summary>
/// Aggregated guardrail evaluation across all registered guardrails.
/// </summary>
public sealed class GuardrailEvaluation
{
    public IReadOnlyList<GuardrailResult> Results { get; init; } = Array.Empty<GuardrailResult>();

    /// <summary>True when no mandatory guardrail is failing — the wipe may proceed.</summary>
    public bool Allowed => Results.All(r => r.Passed || !r.Mandatory);

    /// <summary>Mandatory guardrails that are currently failing (the reason for a BLOCKED state).</summary>
    public IEnumerable<GuardrailResult> BlockingFailures =>
        Results.Where(r => !r.Passed && r.Mandatory);
}

/// <summary>
/// A pluggable wipe guardrail. Implementations live in the Guardrails project (and
/// can be added by the customer) and are discovered via DI. Each guardrail is
/// configuration-driven (enable/disable, thresholds, mandatory vs warning).
/// </summary>
public interface IWipeGuardrail
{
    /// <summary>Stable identifier used in config and audit (e.g. "encryption").</summary>
    string Id { get; }

    /// <summary>Evaluate the guardrail against the device context.</summary>
    Task<GuardrailResult> EvaluateAsync(DeviceContext context, CancellationToken ct);
}

/// <summary>
/// Runs all enabled guardrails and aggregates the result, honoring any approved override.
/// </summary>
public interface IGuardrailEngine
{
    Task<GuardrailEvaluation> EvaluateAsync(
        DeviceContext context,
        IReadOnlySet<string>? overriddenGuardrailIds,
        CancellationToken ct);
}
