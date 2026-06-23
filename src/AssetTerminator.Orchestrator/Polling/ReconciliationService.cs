using System.Text.Json;
using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Options;
using AssetTerminator.Orchestrator.Orchestration;
using AssetTerminator.Orchestrator.Services;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Orchestrator.Polling;

/// <summary>
/// Reconciles active decommission requests over time. Verifies the real state of each
/// outstanding sub-action (Intune wipe completion, device absence in Entra/Intune, on-prem
/// agent results), applies retry-with-backoff for transient failures, enforces the SLA and
/// the configurable give-up timeout, and pushes ServiceNow callbacks on meaningful changes.
/// </summary>
public sealed class ReconciliationService
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private readonly IStateStore _store;
    private readonly IAuditWriter _audit;
    private readonly IWipeProvider _wipe;
    private readonly IEnumerable<IDeviceCleanupProvider> _providers;
    private readonly ISlaCalculator _sla;
    private readonly CallbackPublisher _callbacks;
    private readonly IOptionsMonitor<OrchestrationOptions> _orchestration;
    private readonly IOptionsMonitor<SlaOptions> _slaOptions;
    private readonly ILogger<ReconciliationService> _logger;

    public ReconciliationService(
        IStateStore store,
        IAuditWriter audit,
        IWipeProvider wipe,
        IEnumerable<IDeviceCleanupProvider> providers,
        ISlaCalculator sla,
        CallbackPublisher callbacks,
        IOptionsMonitor<OrchestrationOptions> orchestration,
        IOptionsMonitor<SlaOptions> slaOptions,
        ILogger<ReconciliationService> logger)
    {
        _store = store;
        _audit = audit;
        _wipe = wipe;
        _providers = providers;
        _sla = sla;
        _callbacks = callbacks;
        _orchestration = orchestration;
        _slaOptions = slaOptions;
        _logger = logger;
    }

    public async Task ReconcileAllAsync(int batchSize, CancellationToken ct)
    {
        var active = await _store.GetActiveAsync(batchSize, ct);
        _logger.LogInformation("Reconciling {Count} active requests", active.Count);
        foreach (var record in active)
            await ReconcileAsync(record, ct);
    }

    public async Task ReconcileAsync(DecommissionRecord record, CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;
        var previousState = record.State;
        var previousSla = record.SlaState;

        // --- Give-up / timeout ---
        if (now >= record.DueAtUtc)
        {
            await TimeOutAsync(record, ct);
            return;
        }

        // --- SLA state ---
        record.SlaState = _sla.Evaluate(record.AssetCategory, record.CreatedAtUtc, now);

        var context = LoadContext(record);
        var slaCfg = _slaOptions.CurrentValue.For(record.AssetCategory);

        foreach (var action in record.Actions.Where(a => !IsTerminal(a.Status)))
        {
            if (action.NextAttemptUtc is { } next && next > now)
                continue; // still backing off

            await ReconcileActionAsync(record, action, context, slaCfg, ct);
        }

        var newState = DecommissionActivities.OverallState(record);
        if (record.State != RequestState.GuardrailsFailed)
            record.State = newState;

        await _store.UpdateAsync(record, ct);

        // --- Notifications on meaningful changes ---
        if (record.State != previousState)
        {
            await _callbacks.PublishAsync(record, "StateChanged", ct);
        }
        else if (record.SlaState != previousSla && record.SlaState != SlaState.WithinSla)
        {
            await _audit.AppendAsync(SlaAudit(record), ct);
            await _callbacks.PublishAsync(record, record.SlaState == SlaState.Breached ? "SlaBreached" : "SlaAtRisk", ct);
        }
    }

    private async Task ReconcileActionAsync(
        DecommissionRecord record, SubAction action, DeviceContext context, SlaCategoryOptions slaCfg, CancellationToken ct)
    {
        action.LastCheckedUtc = DateTimeOffset.UtcNow;

        ProviderResult result;
        if (action.Target == DecommissionTarget.Wipe)
        {
            result = await _wipe.GetWipeStatusAsync(context, ct);
        }
        else
        {
            var provider = _providers.FirstOrDefault(p => p.Target == action.Target);
            if (provider is null)
            {
                // On-prem actions without a provider in this host are owned by the agent; just wait.
                return;
            }
            result = await provider.GetStatusAsync(context, ct);
        }

        if (result.Status == ActionStatus.Success)
        {
            action.Status = ActionStatus.Success;
            action.FinalOutcome = "Success";
            action.Details = result.Detail ?? "completed";
            action.NextAttemptUtc = null;
            await Audit(record, "ActionCompleted", action.Target.ToString(), "Success", result.Detail, ct);
            return;
        }

        // Not yet complete (device offline / still present / transient failure): retry with backoff.
        action.RetryCount++;
        if (!result.Transient && result.Status == ActionStatus.Failed)
        {
            // Permanent failure.
            action.Status = ActionStatus.Failed;
            action.FinalOutcome = "Failed";
            action.Details = result.Detail;
            action.NextAttemptUtc = null;
            await Audit(record, "ActionFailed", action.Target.ToString(), "Failed", result.Detail, ct);
            return;
        }

        if (action.RetryCount >= slaCfg.MaxRetries)
        {
            action.Status = ActionStatus.Failed;
            action.FinalOutcome = "Failed";
            action.Details = $"max retries ({slaCfg.MaxRetries}) exceeded: {result.Detail}";
            action.NextAttemptUtc = null;
            await Audit(record, "ActionFailed", action.Target.ToString(), "Failed", action.Details, ct);
            return;
        }

        action.Status = ActionStatus.InProgress;
        action.Details = result.Detail ?? "pending";
        action.NextAttemptUtc = DateTimeOffset.UtcNow + ComputeBackoff(action.RetryCount);
    }

    private TimeSpan ComputeBackoff(int retryCount)
    {
        var cfg = _orchestration.CurrentValue;
        var delay = TimeSpan.FromTicks(cfg.RetryBaseDelay.Ticks * (long)Math.Pow(2, Math.Min(retryCount, 20)));
        return delay > cfg.RetryMaxDelay ? cfg.RetryMaxDelay : delay;
    }

    private async Task TimeOutAsync(DecommissionRecord record, CancellationToken ct)
    {
        foreach (var action in record.Actions.Where(a => !IsTerminal(a.Status)))
        {
            action.Status = ActionStatus.TimedOut;
            action.FinalOutcome = "TimedOut";
            action.NextAttemptUtc = null;
        }
        record.State = RequestState.TimedOut;
        await _store.UpdateAsync(record, ct);
        await Audit(record, "RequestTimedOut", null, "TimedOut", $"exceeded max duration (due {record.DueAtUtc:O})", ct);
        await _callbacks.PublishAsync(record, "TimedOut", ct);
        _logger.LogWarning("Request {RequestId} timed out", record.RequestId);
    }

    private static bool IsTerminal(ActionStatus status) =>
        status is ActionStatus.Success or ActionStatus.Skipped or ActionStatus.Failed
            or ActionStatus.Blocked or ActionStatus.TimedOut;

    private static DeviceContext LoadContext(DecommissionRecord record) =>
        string.IsNullOrWhiteSpace(record.DeviceContextJson)
            ? DeviceContextFactory.FromRecord(record)
            : JsonSerializer.Deserialize<DeviceContext>(record.DeviceContextJson, Json) ?? DeviceContextFactory.FromRecord(record);

    private AuditRecord SlaAudit(DecommissionRecord r) => new()
    {
        CorrelationId = r.CorrelationId,
        RequestId = r.RequestId,
        TicketNumber = r.TicketNumber,
        AssetId = r.AssetId,
        Action = "SlaStateChanged",
        Actor = "system",
        Outcome = r.SlaState.ToString()
    };

    private Task Audit(DecommissionRecord r, string action, string? target, string outcome, string? reason, CancellationToken ct) =>
        _audit.AppendAsync(new AuditRecord
        {
            CorrelationId = r.CorrelationId,
            RequestId = r.RequestId,
            TicketNumber = r.TicketNumber,
            AssetId = r.AssetId,
            Action = action,
            TargetEnvironment = target,
            Actor = "system",
            Outcome = outcome,
            Reason = reason
        }, ct);
}
