using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;

namespace AssetTerminator.Infrastructure.Realtime;

/// <summary>No-op realtime publisher used when the Event Grid topic is not configured.</summary>
public sealed class NullRealtimeEventPublisher : IRealtimeEventPublisher
{
    public static readonly NullRealtimeEventPublisher Instance = new();

    public Task PublishStateChangeAsync(DecommissionRecord record, CancellationToken ct) => Task.CompletedTask;
}
