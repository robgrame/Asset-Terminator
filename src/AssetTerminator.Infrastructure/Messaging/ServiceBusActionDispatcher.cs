using System.Text.Json;
using Azure.Messaging.ServiceBus;
using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Options;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Infrastructure.Messaging;

/// <summary>
/// Envelope placed on the cloud / on-prem action queues. The consumer (orchestrator
/// activity or on-prem agent) loads the full state from the store using RequestId.
/// </summary>
public sealed class ActionDispatchMessage
{
    public string RequestId { get; set; } = string.Empty;
    public DecommissionTarget Target { get; set; }
    public DateTimeOffset EnqueuedAtUtc { get; set; } = DateTimeOffset.UtcNow;
}

/// <summary>
/// Routes a sub-action to the correct Service Bus queue: on-prem targets (AD, SCCM)
/// go to the on-prem queue consumed by the self-hosted agent; everything else goes
/// to the cloud queue.
/// </summary>
public sealed class ServiceBusActionDispatcher : IActionDispatcher
{
    private readonly ServiceBusClient _client;
    private readonly MessagingOptions _options;
    private readonly ILogger<ServiceBusActionDispatcher> _logger;

    public ServiceBusActionDispatcher(
        ServiceBusClient client,
        IOptions<MessagingOptions> options,
        ILogger<ServiceBusActionDispatcher> logger)
    {
        _client = client;
        _options = options.Value;
        _logger = logger;
    }

    public async Task DispatchAsync(string requestId, DecommissionTarget target, CancellationToken ct)
    {
        var queue = IsOnPrem(target) ? _options.OnPremActionsQueue : _options.CloudActionsQueue;
        await using var sender = _client.CreateSender(queue);

        var message = new ActionDispatchMessage { RequestId = requestId, Target = target };
        var body = JsonSerializer.SerializeToUtf8Bytes(message);
        var sbMessage = new ServiceBusMessage(body)
        {
            ContentType = "application/json",
            // Dedupe identical (request, target) dispatches inside the SB dedup window.
            MessageId = $"{requestId}:{target}",
            Subject = target.ToString()
        };

        await sender.SendMessageAsync(sbMessage, ct);
        _logger.LogInformation("Dispatched {Target} for {RequestId} to queue {Queue}", target, requestId, queue);
    }

    private static bool IsOnPrem(DecommissionTarget target) =>
        target is DecommissionTarget.ActiveDirectory or DecommissionTarget.ConfigMgr;
}
