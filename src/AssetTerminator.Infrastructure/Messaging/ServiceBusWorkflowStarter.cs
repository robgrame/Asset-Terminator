using System.Text.Json;
using Azure.Messaging.ServiceBus;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Options;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Infrastructure.Messaging;

/// <summary>
/// Service Bus implementation of <see cref="IWorkflowStarter"/>. Sends a
/// <see cref="WorkflowStartMessage"/> to the orchestration queue.
/// </summary>
public sealed class ServiceBusWorkflowStarter : IWorkflowStarter
{
    private readonly ServiceBusClient _client;
    private readonly MessagingOptions _options;
    private readonly ILogger<ServiceBusWorkflowStarter> _logger;

    public ServiceBusWorkflowStarter(
        ServiceBusClient client,
        IOptions<MessagingOptions> options,
        ILogger<ServiceBusWorkflowStarter> logger)
    {
        _client = client;
        _options = options.Value;
        _logger = logger;
    }

    public async Task StartAsync(string requestId, string correlationId, CancellationToken ct)
    {
        await using var sender = _client.CreateSender(_options.OrchestrationQueue);
        var message = new WorkflowStartMessage { RequestId = requestId, CorrelationId = correlationId };
        var body = JsonSerializer.SerializeToUtf8Bytes(message);
        await sender.SendMessageAsync(new ServiceBusMessage(body)
        {
            ContentType = "application/json",
            MessageId = requestId // dedupe duplicate starts within the SB dedup window
        }, ct);
        _logger.LogInformation("Enqueued orchestration start for {RequestId} ({CorrelationId})", requestId, correlationId);
    }
}
