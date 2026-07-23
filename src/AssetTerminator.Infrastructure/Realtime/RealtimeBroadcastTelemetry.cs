using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Guardrails;

namespace AssetTerminator.Infrastructure.Realtime;

/// <summary>
/// Decorator over <see cref="IOperationalTelemetry"/> that also fans a request state change out
/// to the realtime channel on every <see cref="RequestSnapshotAsync"/> call (which already fires
/// on every state transition). Keeps the live board wiring out of the orchestration call sites.
/// </summary>
public sealed class RealtimeBroadcastTelemetry : IOperationalTelemetry
{
    private readonly IOperationalTelemetry _inner;
    private readonly IRealtimeEventPublisher _realtime;

    public RealtimeBroadcastTelemetry(IOperationalTelemetry inner, IRealtimeEventPublisher realtime)
    {
        _inner = inner;
        _realtime = realtime;
    }

    public async Task RequestSnapshotAsync(DecommissionRecord record, CancellationToken ct)
    {
        await _realtime.PublishStateChangeAsync(record, ct);
        await _inner.RequestSnapshotAsync(record, ct);
    }

    public Task ActionSnapshotAsync(DecommissionRecord record, SubAction action, CancellationToken ct) =>
        _inner.ActionSnapshotAsync(record, action, ct);

    public Task GuardrailResultsAsync(DecommissionRecord record, IReadOnlyList<GuardrailResult> results, CancellationToken ct) =>
        _inner.GuardrailResultsAsync(record, results, ct);

    public Task CallbackEventAsync(DecommissionRecord record, string eventType, string eventId, bool success, string? detail, CancellationToken ct) =>
        _inner.CallbackEventAsync(record, eventType, eventId, success, detail, ct);
}
