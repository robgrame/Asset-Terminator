using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Guardrails;

namespace AssetTerminator.Infrastructure.Observability;

/// <summary>
/// No-op telemetry emitter used when Log Analytics ingestion is not configured. The flow
/// still emits structured logs through ILogger (Application Insights) elsewhere.
/// </summary>
public sealed class NullOperationalTelemetry : IOperationalTelemetry
{
    public static readonly NullOperationalTelemetry Instance = new();

    public Task RequestSnapshotAsync(DecommissionRecord record, CancellationToken ct) => Task.CompletedTask;
    public Task ActionSnapshotAsync(DecommissionRecord record, SubAction action, CancellationToken ct) => Task.CompletedTask;
    public Task GuardrailResultsAsync(DecommissionRecord record, IReadOnlyList<GuardrailResult> results, CancellationToken ct) => Task.CompletedTask;
    public Task CallbackEventAsync(DecommissionRecord record, string eventType, string eventId, bool success, string? detail, CancellationToken ct) => Task.CompletedTask;
}
