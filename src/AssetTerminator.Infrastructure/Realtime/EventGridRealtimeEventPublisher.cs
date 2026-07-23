using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using Azure.Messaging.EventGrid;
using Microsoft.Extensions.Logging;

namespace AssetTerminator.Infrastructure.Realtime;

/// <summary>
/// Publishes decommission state changes to an Azure Event Grid custom topic. The Event Grid
/// subscription forwards them to a Function that broadcasts over Azure SignalR to the live
/// operations board. Failures are swallowed and logged — realtime delivery is best-effort.
/// </summary>
public sealed class EventGridRealtimeEventPublisher : IRealtimeEventPublisher
{
    private readonly EventGridPublisherClient _client;
    private readonly string _eventType;
    private readonly ILogger<EventGridRealtimeEventPublisher> _logger;

    public EventGridRealtimeEventPublisher(
        EventGridPublisherClient client,
        string eventType,
        ILogger<EventGridRealtimeEventPublisher> logger)
    {
        _client = client;
        _eventType = eventType;
        _logger = logger;
    }

    public async Task PublishStateChangeAsync(DecommissionRecord r, CancellationToken ct)
    {
        try
        {
            var terminal = r.State is RequestState.Completed or RequestState.Failed
                or RequestState.TimedOut or RequestState.GuardrailsFailed;

            var payload = new RealtimeStateChange
            {
                RequestId = r.RequestId,
                CorrelationId = r.CorrelationId,
                AssetId = r.AssetId,
                DeviceName = r.DeviceName,
                TicketNumber = r.TicketNumber,
                OverallStatus = r.State.ToString(),
                DeviceType = r.DeviceType.ToString(),
                AssetCategory = r.AssetCategory.ToString(),
                DispositionType = r.DispositionType.ToString(),
                SlaState = r.SlaState.ToString(),
                DryRun = r.DryRun,
                CreatedAt = r.CreatedAtUtc,
                UpdatedAt = r.LastUpdatedAtUtc,
                DueAt = r.DueAtUtc == default ? null : r.DueAtUtc,
                Terminal = terminal
            };

            var evt = new EventGridEvent(
                subject: $"decommission/{r.RequestId}",
                eventType: _eventType,
                dataVersion: "1.0",
                data: BinaryData.FromObjectAsJson(payload));

            await _client.SendEventAsync(evt, ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Realtime state-change publish failed for {RequestId}", r.RequestId);
        }
    }
}
