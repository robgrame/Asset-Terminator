using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using Microsoft.Extensions.Logging;

namespace AssetTerminator.Orchestrator.Services;

/// <summary>
/// Builds and sends ServiceNow push callbacks from the current request state, and
/// mirrors the callback into the immutable audit. Each callback carries a unique
/// eventId for idempotent processing on the ServiceNow side.
/// </summary>
public sealed class CallbackPublisher
{
    private readonly ICallbackSender _sender;
    private readonly IAuditWriter _audit;
    private readonly ILogger<CallbackPublisher> _logger;

    public CallbackPublisher(ICallbackSender sender, IAuditWriter audit, ILogger<CallbackPublisher> logger)
    {
        _sender = sender;
        _audit = audit;
        _logger = logger;
    }

    public async Task PublishAsync(DecommissionRecord record, string eventType, CancellationToken ct)
    {
        var callback = new ServiceNowCallback
        {
            RequestId = record.RequestId,
            CorrelationId = record.CorrelationId,
            TicketNumber = record.TicketNumber,
            OverallStatus = record.State.ToString(),
            EventType = eventType,
            Details = new Dictionary<string, object?>
            {
                ["slaState"] = record.SlaState.ToString(),
                ["dueAt"] = record.DueAtUtc,
                ["actions"] = record.Actions.Select(a => new
                {
                    target = a.Target.ToString(),
                    action = a.Action,
                    status = a.Status.ToString(),
                    retryCount = a.RetryCount,
                    details = a.Details
                })
            }
        };

        await _audit.AppendAsync(new AuditRecord
        {
            CorrelationId = record.CorrelationId,
            RequestId = record.RequestId,
            TicketNumber = record.TicketNumber,
            AssetId = record.AssetId,
            Action = "CallbackSent",
            Actor = "system",
            Outcome = record.State.ToString(),
            Reason = eventType
        }, ct);

        await _sender.SendAsync(callback, ct);
        _logger.LogInformation("Published callback {Event} for {RequestId} status={Status}",
            eventType, record.RequestId, record.State);
    }
}

/// <summary>Builds a <see cref="DeviceContext"/> from a persisted record.</summary>
public static class DeviceContextFactory
{
    public static DeviceContext FromRecord(DecommissionRecord r) => new()
    {
        RequestId = r.RequestId,
        CorrelationId = r.CorrelationId,
        DeviceName = r.DeviceName,
        SerialNumber = r.SerialNumber,
        PrimaryUserUpn = r.PrimaryUserUpn,
        DeviceType = r.DeviceType,
        AssetCategory = r.AssetCategory
    };
}
