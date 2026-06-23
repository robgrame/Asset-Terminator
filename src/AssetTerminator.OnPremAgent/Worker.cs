using System.Text.Json;
using Azure.Messaging.ServiceBus;
using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Options;
using AssetTerminator.Infrastructure.Messaging;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AssetTerminator.OnPremAgent;

/// <summary>
/// Self-hosted on-prem agent. Polls the on-prem Service Bus queue for AD / SCCM delete
/// actions dispatched by the orchestrator, executes them against the on-prem directory
/// and ConfigMgr AdminService, writes the outcome back to the shared state store and the
/// immutable audit. Runs inside the customer network with line-of-sight to the DC and
/// the SCCM site server.
/// </summary>
public sealed class Worker : BackgroundService
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private readonly ServiceBusClient _client;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly MessagingOptions _messaging;
    private readonly ILogger<Worker> _logger;
    private ServiceBusProcessor? _processor;

    public Worker(
        ServiceBusClient client,
        IServiceScopeFactory scopeFactory,
        IOptions<MessagingOptions> messaging,
        ILogger<Worker> logger)
    {
        _client = client;
        _scopeFactory = scopeFactory;
        _messaging = messaging.Value;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _processor = _client.CreateProcessor(_messaging.OnPremActionsQueue, new ServiceBusProcessorOptions
        {
            AutoCompleteMessages = false,
            MaxConcurrentCalls = 1
        });

        _processor.ProcessMessageAsync += OnMessageAsync;
        _processor.ProcessErrorAsync += OnErrorAsync;

        _logger.LogInformation("On-prem agent listening on queue {Queue}", _messaging.OnPremActionsQueue);
        await _processor.StartProcessingAsync(stoppingToken);

        try
        {
            await Task.Delay(Timeout.Infinite, stoppingToken);
        }
        catch (OperationCanceledException)
        {
            // graceful shutdown
        }
        finally
        {
            await _processor.StopProcessingAsync(CancellationToken.None);
        }
    }

    private async Task OnMessageAsync(ProcessMessageEventArgs args)
    {
        var ct = args.CancellationToken;
        ActionDispatchMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<ActionDispatchMessage>(args.Message.Body.ToString(), Json);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Malformed on-prem message; dead-lettering");
            await args.DeadLetterMessageAsync(args.Message, "MalformedJson", ex.Message, ct);
            return;
        }

        if (message is null || string.IsNullOrWhiteSpace(message.RequestId))
        {
            await args.DeadLetterMessageAsync(args.Message, "EmptyMessage", "missing requestId", ct);
            return;
        }

        try
        {
            await ProcessAsync(message, ct);
            await args.CompleteMessageAsync(args.Message, ct);
        }
        catch (Exception ex)
        {
            // Let Service Bus redeliver (retry); after max delivery count it dead-letters.
            _logger.LogError(ex, "Processing failed for {RequestId}/{Target}; abandoning for retry",
                message.RequestId, message.Target);
            await args.AbandonMessageAsync(args.Message, cancellationToken: ct);
        }
    }

    private async Task ProcessAsync(ActionDispatchMessage message, CancellationToken ct)
    {
        using var scope = _scopeFactory.CreateScope();
        var store = scope.ServiceProvider.GetRequiredService<IStateStore>();
        var audit = scope.ServiceProvider.GetRequiredService<IAuditWriter>();
        var telemetry = scope.ServiceProvider.GetRequiredService<IOperationalTelemetry>();
        var providers = scope.ServiceProvider.GetServices<IDeviceCleanupProvider>();

        var record = await store.GetAsync(message.RequestId, ct);
        if (record is null)
        {
            _logger.LogWarning("Request {RequestId} not found in state store; ignoring", message.RequestId);
            return;
        }

        var provider = providers.FirstOrDefault(p => p.Target == message.Target);
        if (provider is null)
        {
            _logger.LogWarning("No on-prem provider for {Target}", message.Target);
            return;
        }

        var action = record.Actions.FirstOrDefault(a => a.Target == message.Target);
        if (action is null)
        {
            _logger.LogWarning("No {Target} sub-action on request {RequestId}", message.Target, message.RequestId);
            return;
        }

        var context = BuildContext(record);
        action.LastCheckedUtc = DateTimeOffset.UtcNow;
        action.RetryCount++;

        await Audit(audit, record, "DeleteAttempted", message.Target, "InProgress", null, ct); // write-before-action
        var result = await provider.DeleteAsync(context, ct);
        ApplyResult(action, result);
        await store.UpdateAsync(record, ct);
        await Audit(audit, record, "DeleteCompleted", message.Target, action.Status.ToString(), result.Detail, ct);
        await telemetry.ActionSnapshotAsync(record, action, ct);

        _logger.LogInformation("On-prem {Target} for {RequestId} -> {Status}",
            message.Target, message.RequestId, action.Status);
    }

    private static DeviceContext BuildContext(DecommissionRecord r)
    {
        if (!string.IsNullOrWhiteSpace(r.DeviceContextJson))
        {
            var ctx = JsonSerializer.Deserialize<DeviceContext>(r.DeviceContextJson, Json);
            if (ctx is not null)
                return ctx;
        }

        return new DeviceContext
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

    private static void ApplyResult(SubAction action, ProviderResult result)
    {
        action.Status = result.Status;
        action.Details = result.Detail;
        if (result.Status is ActionStatus.Success or ActionStatus.Skipped)
            action.FinalOutcome = result.Status.ToString();
        else if (result.Status == ActionStatus.Failed && result.Transient)
            action.Status = ActionStatus.InProgress; // transient: SB redelivery / poller will retry
        else if (result.Status == ActionStatus.Failed)
            action.FinalOutcome = "Failed";
    }

    private Task OnErrorAsync(ProcessErrorEventArgs args)
    {
        _logger.LogError(args.Exception, "Service Bus processing error in {Source}", args.ErrorSource);
        return Task.CompletedTask;
    }

    private static Task Audit(
        IAuditWriter audit, DecommissionRecord r, string action, DecommissionTarget target,
        string outcome, string? reason, CancellationToken ct) =>
        audit.AppendAsync(new AuditRecord
        {
            CorrelationId = r.CorrelationId,
            RequestId = r.RequestId,
            TicketNumber = r.TicketNumber,
            AssetId = r.AssetId,
            Action = action,
            TargetEnvironment = target.ToString(),
            Actor = "onprem-agent",
            Outcome = outcome,
            Reason = reason
        }, ct);
}
