using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Guardrails;

namespace AssetTerminator.Infrastructure.Realtime;

/// <summary>
/// Decorator over <see cref="IOperationalTelemetry"/> that also fans a request state change out
/// to the realtime channel whenever <see cref="RequestSnapshotAsync"/> is called. Realtime delivery
/// is strictly best-effort: the primary telemetry runs first and the broadcast is bounded by a short
/// timeout so a slow/unavailable Event Grid can never delay the orchestration path.
/// </summary>
public sealed class RealtimeBroadcastTelemetry : IOperationalTelemetry
{
    private static readonly TimeSpan BroadcastTimeout = TimeSpan.FromSeconds(5);

    private readonly IOperationalTelemetry _inner;
    private readonly IRealtimeEventPublisher _realtime;

    public RealtimeBroadcastTelemetry(IOperationalTelemetry inner, IRealtimeEventPublisher realtime)
    {
        _inner = inner;
        _realtime = realtime;
    }

    public async Task RequestSnapshotAsync(DecommissionRecord record, CancellationToken ct)
    {
        // Primary telemetry first — it must never be blocked or preceded by best-effort realtime.
        await _inner.RequestSnapshotAsync(record, ct);

        using var timeout = new CancellationTokenSource(BroadcastTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, timeout.Token);
        await _realtime.PublishStateChangeAsync(record, linked.Token);
    }

    public Task ActionSnapshotAsync(DecommissionRecord record, SubAction action, CancellationToken ct) =>
        _inner.ActionSnapshotAsync(record, action, ct);

    public Task GuardrailResultsAsync(DecommissionRecord record, IReadOnlyList<GuardrailResult> results, CancellationToken ct) =>
        _inner.GuardrailResultsAsync(record, results, ct);

    public Task CallbackEventAsync(DecommissionRecord record, string eventType, string eventId, bool success, string? detail, CancellationToken ct) =>
        _inner.CallbackEventAsync(record, eventType, eventId, success, detail, ct);
}
