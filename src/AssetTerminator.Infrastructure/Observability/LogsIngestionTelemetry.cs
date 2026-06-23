using Azure.Monitor.Ingestion;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Guardrails;
using AssetTerminator.Core.Options;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Infrastructure.Observability;

/// <summary>
/// Emits operational telemetry to Log Analytics custom tables via the Azure Monitor Logs
/// Ingestion API (Data Collection Rule + Endpoint). Row property names map to the custom
/// table columns through the DCR transform (e.g. <c>requestId</c> -&gt; <c>requestId_s</c>).
/// All failures are swallowed and logged — telemetry must never break the decommission flow.
/// </summary>
public sealed class LogsIngestionTelemetry : IOperationalTelemetry
{
    private readonly LogsIngestionClient _client;
    private readonly ObservabilityOptions _options;
    private readonly ILogger<LogsIngestionTelemetry> _logger;

    public LogsIngestionTelemetry(
        LogsIngestionClient client,
        IOptions<ObservabilityOptions> options,
        ILogger<LogsIngestionTelemetry> logger)
    {
        _client = client;
        _options = options.Value;
        _logger = logger;
    }

    public Task RequestSnapshotAsync(DecommissionRecord r, CancellationToken ct)
    {
        var terminal = r.State is RequestState.Completed or RequestState.Failed
            or RequestState.TimedOut or RequestState.GuardrailsFailed;
        return UploadAsync(_options.RequestsStream, new[]
        {
            new Dictionary<string, object?>
            {
                ["TimeGenerated"] = DateTimeOffset.UtcNow,
                ["requestId"] = r.RequestId,
                ["correlationId"] = r.CorrelationId,
                ["assetId"] = r.AssetId,
                ["ticketNumber"] = r.TicketNumber,
                ["overallStatus"] = r.State.ToString(),
                ["deviceType"] = r.DeviceType.ToString(),
                ["assetCategory"] = r.AssetCategory.ToString(),
                ["slaState"] = r.SlaState.ToString(),
                ["dryRun"] = r.DryRun,
                ["createdAt"] = r.CreatedAtUtc,
                ["completedAt"] = terminal ? r.LastUpdatedAtUtc : (DateTimeOffset?)null,
                ["dueAt"] = r.DueAtUtc
            }
        }, ct);
    }

    public Task ActionSnapshotAsync(DecommissionRecord r, SubAction a, CancellationToken ct) =>
        UploadAsync(_options.ActionsStream, new[]
        {
            new Dictionary<string, object?>
            {
                ["TimeGenerated"] = DateTimeOffset.UtcNow,
                ["requestId"] = r.RequestId,
                ["correlationId"] = r.CorrelationId,
                ["ticketNumber"] = r.TicketNumber,
                ["target"] = a.Target.ToString(),
                ["system"] = a.Target.ToString(),
                ["action"] = a.Action,
                ["status"] = a.Status.ToString(),
                ["retryCount"] = a.RetryCount,
                ["assetCategory"] = r.AssetCategory.ToString(),
                ["lastChecked"] = a.LastCheckedUtc,
                ["detail"] = a.Details
            }
        }, ct);

    public Task GuardrailResultsAsync(DecommissionRecord r, IReadOnlyList<GuardrailResult> results, CancellationToken ct)
    {
        if (results.Count == 0)
            return Task.CompletedTask;

        var rows = results.Select(g => new Dictionary<string, object?>
        {
            ["TimeGenerated"] = DateTimeOffset.UtcNow,
            ["requestId"] = r.RequestId,
            ["correlationId"] = r.CorrelationId,
            ["ticketNumber"] = r.TicketNumber,
            ["assetCategory"] = r.AssetCategory.ToString(),
            ["guardrailId"] = g.GuardrailId,
            ["passed"] = g.Passed,
            ["severity"] = g.Severity.ToString(),
            ["mandatory"] = g.Mandatory,
            ["overridable"] = g.Overridable,
            ["reason"] = g.Reason
        }).ToList();

        return UploadAsync(_options.GuardrailsStream, rows, ct);
    }

    public Task CallbackEventAsync(DecommissionRecord r, string eventType, string eventId, bool success, string? detail, CancellationToken ct) =>
        UploadAsync(_options.CallbacksStream, new[]
        {
            new Dictionary<string, object?>
            {
                ["TimeGenerated"] = DateTimeOffset.UtcNow,
                ["requestId"] = r.RequestId,
                ["correlationId"] = r.CorrelationId,
                ["ticketNumber"] = r.TicketNumber,
                ["eventType"] = eventType,
                ["eventId"] = eventId,
                ["overallStatus"] = r.State.ToString(),
                ["success"] = success,
                ["detail"] = detail
            }
        }, ct);

    private async Task UploadAsync(string stream, IEnumerable<Dictionary<string, object?>> rows, CancellationToken ct)
    {
        try
        {
            await _client.UploadAsync(_options.DcrImmutableId, stream, rows.ToList(), cancellationToken: ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Telemetry upload to {Stream} failed", stream);
        }
    }
}
