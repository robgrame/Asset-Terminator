namespace AssetTerminator.Core.Abstractions;

/// <summary>
/// Message used to start the orchestration workflow for a request. Placed on the
/// orchestration queue by the HTTP intake; consumed by the orchestrator host which
/// kicks off the Durable Functions orchestration. This decouples ingestion from the
/// (long-running) orchestration.
/// </summary>
public sealed class WorkflowStartMessage
{
    public string RequestId { get; set; } = string.Empty;
    public string CorrelationId { get; set; } = string.Empty;
    public DateTimeOffset EnqueuedAtUtc { get; set; } = DateTimeOffset.UtcNow;
}

/// <summary>
/// Enqueues a request for orchestration. Implemented over Service Bus.
/// </summary>
public interface IWorkflowStarter
{
    Task StartAsync(string requestId, string correlationId, CancellationToken ct);
}
