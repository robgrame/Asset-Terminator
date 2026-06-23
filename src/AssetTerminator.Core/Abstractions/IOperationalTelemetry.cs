using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Guardrails;

namespace AssetTerminator.Core.Abstractions;

/// <summary>
/// Emits structured operational telemetry to the analytics backend (Log Analytics custom
/// tables by default: DecommissionRequests_CL, DecommissionActions_CL, GuardrailResults_CL,
/// CallbackEvents_CL) feeding the KQL library and the Azure Monitor workbook.
/// Implementations MUST never throw into the caller — observability failures must not
/// break the decommission flow.
/// </summary>
public interface IOperationalTelemetry
{
    /// <summary>Emit a snapshot of the overall request state (one row per state change).</summary>
    Task RequestSnapshotAsync(DecommissionRecord record, CancellationToken ct);

    /// <summary>Emit a snapshot of a single sub-action.</summary>
    Task ActionSnapshotAsync(DecommissionRecord record, SubAction action, CancellationToken ct);

    /// <summary>Emit the guardrail evaluation results for a request.</summary>
    Task GuardrailResultsAsync(DecommissionRecord record, IReadOnlyList<GuardrailResult> results, CancellationToken ct);

    /// <summary>Emit a ServiceNow callback event.</summary>
    Task CallbackEventAsync(DecommissionRecord record, string eventType, string eventId, bool success, string? detail, CancellationToken ct);
}
