using System.Text.Json;
using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Guardrails;
using AssetTerminator.Core.Options;
using AssetTerminator.Orchestrator.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Orchestrator.Orchestration;

/// <summary>Serializable metadata returned by the validate/enrich activity.</summary>
public sealed record RequestMeta(
    bool DryRun,
    DispositionType Disposition,
    List<DecommissionTarget> Targets,
    TimeSpan PreWipePollInterval,
    bool RequirePreWipeCompletion);

/// <summary>Serializable guardrail outcome passed back to the orchestrator.</summary>
public sealed record GuardrailOutcome(bool Allowed, List<string> BlockingReasons);

/// <summary>Completion state of the on-device pre-wipe preventive actions.</summary>
public sealed record PreWipeStatus(bool AllTerminal, bool AllSucceeded, bool DeadlinePassed, List<string> FailedReasons);

/// <summary>
/// Durable activity functions. Each activity loads the current state from the store by
/// requestId (the durable input is a plain string), performs one well-scoped unit of
/// work, persists state, and writes an audit record before/after destructive actions.
/// </summary>
public sealed class DecommissionActivities
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private readonly IStateStore _store;
    private readonly IAuditWriter _audit;
    private readonly IGuardrailEngine _guardrails;
    private readonly IDeviceEnricher _enricher;
    private readonly IActionDispatcher _dispatcher;
    private readonly IEnumerable<IDeviceCleanupProvider> _providers;
    private readonly IWipeProvider _wipe;
    private readonly IRetireProvider _retire;
    private readonly CallbackPublisher _callbacks;
    private readonly IOperationalTelemetry _telemetry;
    private readonly OrchestrationOptions _orchestration;
    private readonly PreWipeOptions _preWipe;
    private readonly ILogger<DecommissionActivities> _logger;

    public DecommissionActivities(
        IStateStore store,
        IAuditWriter audit,
        IGuardrailEngine guardrails,
        IDeviceEnricher enricher,
        IActionDispatcher dispatcher,
        IEnumerable<IDeviceCleanupProvider> providers,
        IWipeProvider wipe,
        IRetireProvider retire,
        CallbackPublisher callbacks,
        IOperationalTelemetry telemetry,
        IOptions<OrchestrationOptions> orchestration,
        IOptions<PreWipeOptions> preWipe,
        ILogger<DecommissionActivities> logger)
    {
        _store = store;
        _audit = audit;
        _guardrails = guardrails;
        _enricher = enricher;
        _dispatcher = dispatcher;
        _providers = providers;
        _wipe = wipe;
        _retire = retire;
        _callbacks = callbacks;
        _telemetry = telemetry;
        _orchestration = orchestration.Value;
        _preWipe = preWipe.Value;
        _logger = logger;
    }

    [Function(nameof(EnrichAndValidate))]
    public async Task<RequestMeta> EnrichAndValidate([ActivityTrigger] string requestId, CancellationToken ct)
    {
        var record = await Load(requestId, ct);

        var context = DeviceContextFactory.FromRecord(record);
        await _enricher.EnrichAsync(context, ct);
        record.DeviceContextJson = JsonSerializer.Serialize(context, Json);
        record.State = RequestState.Validated;
        await _store.UpdateAsync(record, ct);

        await Audit(record, "Validated", null, "Validated",
            $"disposition={record.DispositionType}; intuneId={context.IntuneManagedDeviceId}; entraId={context.EntraDeviceId}; encrypted={context.IsEncrypted}", ct);

        var targets = record.Actions.Select(a => a.Target).ToList();
        return new RequestMeta(
            record.DryRun,
            record.DispositionType,
            targets,
            _orchestration.PreWipePollInterval,
            _preWipe.RequireCompletionBeforeWipe);
    }

    [Function(nameof(EvaluateGuardrails))]
    public async Task<GuardrailOutcome> EvaluateGuardrails([ActivityTrigger] string requestId, CancellationToken ct)
    {
        var record = await Load(requestId, ct);
        var context = LoadContext(record);

        var overrides = await _store.GetOverridesAsync(requestId, ct);
        var overriddenIds = overrides.SelectMany(o => o.GuardrailIds).ToHashSet(StringComparer.OrdinalIgnoreCase);
        // An override with no explicit guardrail ids means "bypass all overridable blocks".
        var bypassAll = overrides.Any(o => o.GuardrailIds.Count == 0);

        var evaluation = await _guardrails.EvaluateAsync(context, bypassAll ? null : overriddenIds, ct);

        var effectiveResults = evaluation.Results.ToList();
        if (bypassAll)
        {
            // Re-evaluate treating all overridable blocking failures as passed.
            effectiveResults = effectiveResults
                .Select(r => r is { Passed: false, Overridable: true }
                    ? GuardrailResult.Pass(r.GuardrailId, GuardrailSeverity.Warning)
                    : r)
                .ToList();
        }

        var blocking = effectiveResults.Where(r => !r.Passed && r.Mandatory).ToList();
        var allowed = blocking.Count == 0;

        await _audit.AppendAsync(new AuditRecord
        {
            CorrelationId = record.CorrelationId,
            RequestId = record.RequestId,
            TicketNumber = record.TicketNumber,
            AssetId = record.AssetId,
            Action = "GuardrailsEvaluated",
            TargetEnvironment = DecommissionTarget.Wipe.ToString(),
            Actor = "system",
            Outcome = allowed ? "Passed" : "Blocked",
            Reason = allowed ? null : string.Join("; ", blocking.Select(b => $"{b.GuardrailId}:{b.Reason}")),
            GuardrailResults = evaluation.Results
        }, ct);

        await _telemetry.GuardrailResultsAsync(record, evaluation.Results, ct);

        return new GuardrailOutcome(allowed, blocking.Select(b => $"{b.GuardrailId}: {b.Reason}").ToList());
    }

    [Function(nameof(ExecuteDelete))]
    public async Task ExecuteDelete([ActivityTrigger] DeleteInput input, CancellationToken ct)
    {
        var record = await Load(input.RequestId, ct);
        var context = LoadContext(record);
        var action = record.Actions.First(a => a.Target == input.Target);
        action.LastCheckedUtc = DateTimeOffset.UtcNow;

        if (record.DryRun)
        {
            action.Status = ActionStatus.Skipped;
            action.Details = "[DRY-RUN] delete simulated";
            action.FinalOutcome = "Skipped";
            await _store.UpdateAsync(record, ct);
            await Audit(record, "DeleteSimulated", input.Target.ToString(), "Skipped", "[DRY-RUN]", ct);
            return;
        }

        if (IsOnPrem(input.Target))
        {
            // On-prem deletes are executed by the self-hosted agent via the on-prem queue.
            action.Status = ActionStatus.InProgress;
            action.Details = "dispatched to on-prem agent";
            await _store.UpdateAsync(record, ct);
            await _dispatcher.DispatchAsync(record.RequestId, input.Target, ct);
            await Audit(record, "DeleteDispatched", input.Target.ToString(), "InProgress", "queued for on-prem agent", ct);
            return;
        }

        var provider = _providers.FirstOrDefault(p => p.Target == input.Target);
        if (provider is null)
        {
            action.Status = ActionStatus.Failed;
            action.Details = "no provider registered";
            action.FinalOutcome = "Failed";
            await _store.UpdateAsync(record, ct);
            return;
        }

        await Audit(record, "DeleteAttempted", input.Target.ToString(), "InProgress", null, ct); // write-before-action
        var result = await provider.DeleteAsync(context, ct);
        ApplyResult(action, result);
        await _store.UpdateAsync(record, ct);
        await Audit(record, "DeleteCompleted", input.Target.ToString(), action.Status.ToString(), result.Detail, ct);
        await _telemetry.ActionSnapshotAsync(record, action, ct);
    }

    [Function(nameof(IssueWipe))]
    public async Task IssueWipe([ActivityTrigger] string requestId, CancellationToken ct)
    {
        var record = await Load(requestId, ct);
        var context = LoadContext(record);
        var action = record.Actions.First(a => a.Target == DecommissionTarget.Wipe);
        action.LastCheckedUtc = DateTimeOffset.UtcNow;

        if (record.DryRun)
        {
            action.Status = ActionStatus.Skipped;
            action.Details = "[DRY-RUN] wipe simulated";
            action.FinalOutcome = "Skipped";
            await _store.UpdateAsync(record, ct);
            await Audit(record, "WipeSimulated", "Wipe", "Skipped", "[DRY-RUN]", ct);
            return;
        }

        await Audit(record, "WipeIssued", "Wipe", "InProgress", null, ct); // write-before-action
        var result = await _wipe.WipeAsync(context, ct);
        // The wipe is asynchronous; success here only means the command was accepted.
        action.Status = result.Status == ActionStatus.Failed ? ActionStatus.Failed : ActionStatus.InProgress;
        action.Details = result.Detail ?? "wipe command issued; awaiting completion";
        if (result.Status == ActionStatus.Failed && !result.Transient)
            action.FinalOutcome = "Failed";
        await _store.UpdateAsync(record, ct);
        await Audit(record, "WipeAccepted", "Wipe", action.Status.ToString(), result.Detail, ct);
        await _telemetry.ActionSnapshotAsync(record, action, ct);
    }

    [Function(nameof(ExecuteRetire))]
    public async Task ExecuteRetire([ActivityTrigger] string requestId, CancellationToken ct)
    {
        var record = await Load(requestId, ct);
        var context = LoadContext(record);
        var action = record.Actions.First(a => a.Target == DecommissionTarget.Retire);
        action.LastCheckedUtc = DateTimeOffset.UtcNow;

        if (record.DryRun)
        {
            action.Status = ActionStatus.Skipped;
            action.Details = "[DRY-RUN] retire simulated";
            action.FinalOutcome = "Skipped";
            await _store.UpdateAsync(record, ct);
            await Audit(record, "RetireSimulated", "Retire", "Skipped", "[DRY-RUN]", ct);
            return;
        }

        await Audit(record, "RetireIssued", "Retire", "InProgress", null, ct); // write-before-action
        var result = await _retire.RetireAsync(context, ct);
        // The retire is asynchronous; success here only means the command was accepted.
        action.Status = result.Status == ActionStatus.Failed ? ActionStatus.Failed
            : result.Status == ActionStatus.Skipped ? ActionStatus.Skipped
            : ActionStatus.InProgress;
        action.Details = result.Detail ?? "retire command issued; awaiting completion";
        if (result.Status == ActionStatus.Skipped)
            action.FinalOutcome = "Skipped";
        else if (result.Status == ActionStatus.Failed && !result.Transient)
            action.FinalOutcome = "Failed";
        await _store.UpdateAsync(record, ct);
        await Audit(record, "RetireAccepted", "Retire", action.Status.ToString(), result.Detail, ct);
        await _telemetry.ActionSnapshotAsync(record, action, ct);
    }

    [Function(nameof(CheckPreWipeActions))]
    public async Task<PreWipeStatus> CheckPreWipeActions([ActivityTrigger] CheckPreWipeInput input, CancellationToken ct)
    {
        var record = await Load(input.RequestId, ct);
        var targets = input.Targets.ToHashSet();
        var actions = record.Actions.Where(a => targets.Contains(a.Target)).ToList();

        var allTerminal = actions.All(a => IsTerminal(a.Status));
        var allSucceeded = actions.All(a => a.Status is ActionStatus.Success or ActionStatus.Skipped);
        var deadlinePassed = DateTimeOffset.UtcNow >= record.DueAtUtc;
        var failed = actions
            .Where(a => a.Status is not (ActionStatus.Success or ActionStatus.Skipped))
            .Select(a => $"{a.Target}: {a.Details ?? a.Status.ToString()}")
            .ToList();

        return new PreWipeStatus(allTerminal, allSucceeded, deadlinePassed, failed);
    }

    [Function(nameof(BlockWipe))]
    public async Task BlockWipe([ActivityTrigger] BlockInput input, CancellationToken ct)
    {
        var record = await Load(input.RequestId, ct);
        var action = record.Actions.FirstOrDefault(a => a.Target == DecommissionTarget.Wipe);
        if (action is not null)
        {
            action.Status = ActionStatus.Blocked;
            action.Details = string.Join("; ", input.Reasons);
            action.FinalOutcome = "Blocked";
        }
        record.State = RequestState.GuardrailsFailed;
        await _store.UpdateAsync(record, ct);
        await Audit(record, "WipeBlocked", "Wipe", "Blocked", string.Join("; ", input.Reasons), ct);
        await _callbacks.PublishAsync(record, input.CallbackEvent ?? "GuardrailsBlocked", ct);
    }

    [Function(nameof(Finalize))]
    public async Task Finalize([ActivityTrigger] string requestId, CancellationToken ct)
    {
        var record = await Load(requestId, ct);
        // If already blocked, leave it for the override flow / poller.
        if (record.State == RequestState.GuardrailsFailed)
            return;

        record.State = OverallState(record);
        await _store.UpdateAsync(record, ct);
        await Audit(record, "StateChanged", null, record.State.ToString(), null, ct);
        await _callbacks.PublishAsync(record, "StateChanged", ct);
    }

    internal static RequestState OverallState(DecommissionRecord record)
    {
        var statuses = record.Actions.Select(a => a.Status).ToList();
        if (statuses.All(s => s is ActionStatus.Success or ActionStatus.Skipped))
            return RequestState.Completed;
        if (statuses.Any(s => s is ActionStatus.Pending or ActionStatus.InProgress))
            return RequestState.InProgress;
        if (statuses.Any(s => s == ActionStatus.Success) && statuses.Any(s => s is ActionStatus.Failed or ActionStatus.Blocked))
            return RequestState.PartiallyCompleted;
        if (statuses.All(s => s is ActionStatus.Failed))
            return RequestState.Failed;
        return RequestState.PartiallyCompleted;
    }

    private static void ApplyResult(SubAction action, ProviderResult result)
    {
        action.Status = result.Status;
        action.Details = result.Detail;
        if (result.Status is ActionStatus.Success or ActionStatus.Skipped)
            action.FinalOutcome = result.Status.ToString();
        else if (result.Status == ActionStatus.Failed && result.Transient)
            action.Status = ActionStatus.InProgress; // let the poller retry transient failures
        else if (result.Status == ActionStatus.Failed)
            action.FinalOutcome = "Failed";
    }

    private static bool IsOnPrem(DecommissionTarget t) =>
        t is DecommissionTarget.ActiveDirectory
            or DecommissionTarget.ConfigMgr
            or DecommissionTarget.LicenseRemoval
            or DecommissionTarget.BiosPasswordRemoval;

    private static bool IsTerminal(ActionStatus status) =>
        status is ActionStatus.Success or ActionStatus.Skipped or ActionStatus.Failed
            or ActionStatus.Blocked or ActionStatus.TimedOut;

    private async Task<DecommissionRecord> Load(string requestId, CancellationToken ct) =>
        await _store.GetAsync(requestId, ct)
        ?? throw new InvalidOperationException($"Request '{requestId}' not found.");

    private static DeviceContext LoadContext(DecommissionRecord record) =>
        string.IsNullOrWhiteSpace(record.DeviceContextJson)
            ? DeviceContextFactory.FromRecord(record)
            : JsonSerializer.Deserialize<DeviceContext>(record.DeviceContextJson, Json) ?? DeviceContextFactory.FromRecord(record);

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

/// <summary>Activity input for a delete sub-action.</summary>
public sealed record DeleteInput(string RequestId, DecommissionTarget Target);

/// <summary>Activity input for blocking the wipe. <paramref name="CallbackEvent"/> defaults to "GuardrailsBlocked".</summary>
public sealed record BlockInput(string RequestId, List<string> Reasons, string? CallbackEvent = null);

/// <summary>Activity input for checking completion of the pre-wipe preventive actions.</summary>
public sealed record CheckPreWipeInput(string RequestId, List<DecommissionTarget> Targets);
