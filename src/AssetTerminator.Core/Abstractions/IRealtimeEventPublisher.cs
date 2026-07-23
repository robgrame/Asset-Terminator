using AssetTerminator.Core.Domain;

namespace AssetTerminator.Core.Abstractions;

/// <summary>
/// Publishes decommission state changes to a realtime fan-out channel (Azure Event Grid custom
/// topic) that ultimately drives the live operations board over SignalR. Implementations MUST
/// never throw into the caller — realtime delivery is best-effort and must not break the flow.
/// </summary>
public interface IRealtimeEventPublisher
{
    /// <summary>Publish a single request state-change event.</summary>
    Task PublishStateChangeAsync(DecommissionRecord record, CancellationToken ct);
}
