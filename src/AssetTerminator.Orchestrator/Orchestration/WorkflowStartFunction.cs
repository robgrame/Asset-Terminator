using System.Text.Json;
using AssetTerminator.Core.Abstractions;
using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;
using Microsoft.DurableTask.Client;
using Microsoft.Extensions.Logging;

namespace AssetTerminator.Orchestrator.Orchestration;

/// <summary>
/// Service Bus-triggered starter. Consumes <see cref="WorkflowStartMessage"/> from the
/// orchestration queue (placed by the HTTP intake) and schedules the Durable
/// orchestration. The request id is used as the orchestration instance id, so a
/// duplicate start is ignored — preserving idempotency end-to-end.
/// </summary>
public sealed class WorkflowStartFunction
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly ILogger<WorkflowStartFunction> _logger;

    public WorkflowStartFunction(ILogger<WorkflowStartFunction> logger) => _logger = logger;

    [Function(nameof(WorkflowStartFunction))]
    public async Task Run(
        [ServiceBusTrigger("%AssetTerminator:Messaging:OrchestrationQueue%", Connection = "ServiceBus")] string body,
        [DurableClient] DurableTaskClient durable,
        CancellationToken ct)
    {
        var message = JsonSerializer.Deserialize<WorkflowStartMessage>(body, Json);
        if (message is null || string.IsNullOrWhiteSpace(message.RequestId))
        {
            _logger.LogWarning("Discarding malformed workflow start message");
            return;
        }

        var existing = await durable.GetInstanceAsync(message.RequestId, ct);
        if (existing is not null &&
            existing.RuntimeStatus is Microsoft.DurableTask.Client.OrchestrationRuntimeStatus.Running
                or Microsoft.DurableTask.Client.OrchestrationRuntimeStatus.Pending)
        {
            _logger.LogInformation("Orchestration {RequestId} already active; skipping duplicate start", message.RequestId);
            return;
        }

        await durable.ScheduleNewOrchestrationInstanceAsync(
            nameof(DecommissionOrchestrator),
            message.RequestId,
            new StartOrchestrationOptions(InstanceId: message.RequestId),
            ct);

        _logger.LogInformation("Scheduled orchestration {RequestId}", message.RequestId);
    }
}
