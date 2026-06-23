using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Options;
using Microsoft.Extensions.Logging;

namespace AssetTerminator.Api.Services;

/// <summary>Outcome of validating + persisting an inbound decommission request.</summary>
public sealed record IntakeResult(bool Accepted, bool Created, string CorrelationId, string? Error);

/// <summary>
/// Validates an inbound request, idempotently persists the initial state, writes the
/// "request received" audit record, and enqueues the orchestration workflow.
/// </summary>
public sealed class IntakeService
{
    private readonly IStateStore _store;
    private readonly IAuditWriter _audit;
    private readonly IWorkflowStarter _workflow;
    private readonly ISlaCalculator _sla;
    private readonly ILogger<IntakeService> _logger;

    public IntakeService(
        IStateStore store,
        IAuditWriter audit,
        IWorkflowStarter workflow,
        ISlaCalculator sla,
        ILogger<IntakeService> logger)
    {
        _store = store;
        _audit = audit;
        _workflow = workflow;
        _sla = sla;
        _logger = logger;
    }

    public async Task<IntakeResult> SubmitAsync(DecommissionRequest request, string rawJson, CancellationToken ct)
    {
        var error = Validate(request);
        if (error is not null)
            return new IntakeResult(false, false, string.Empty, error);

        var correlationId = Guid.NewGuid().ToString("N");
        var now = DateTimeOffset.UtcNow;
        var record = new DecommissionRecord
        {
            RequestId = request.RequestId,
            CorrelationId = correlationId,
            AssetId = request.AssetId,
            DeviceName = request.DeviceName,
            SerialNumber = request.SerialNumber,
            PrimaryUserUpn = request.PrimaryUserUpn,
            DeviceType = request.DeviceType,
            AssetCategory = request.AssetCategory,
            TicketNumber = request.TicketNumber,
            Requestor = request.Requestor,
            DryRun = request.DryRun,
            State = RequestState.Requested,
            CreatedAtUtc = now,
            LastUpdatedAtUtc = now,
            DueAtUtc = _sla.ComputeDueAt(request.AssetCategory, now),
            RequestJson = rawJson,
            Actions = request.RequestedActions
                .Distinct()
                .Select(t => new SubAction
                {
                    RequestId = request.RequestId,
                    Target = t,
                    Action = t == DecommissionTarget.Wipe ? "Wipe" : "Delete",
                    Status = ActionStatus.Pending
                })
                .ToList()
        };

        var (persisted, created) = await _store.GetOrCreateAsync(record, ct);

        if (!created)
        {
            // Idempotent: same requestId already accepted — do not start a second workflow.
            _logger.LogInformation("Idempotent replay of {RequestId}", request.RequestId);
            return new IntakeResult(true, false, persisted.CorrelationId, null);
        }

        await _audit.AppendAsync(new AuditRecord
        {
            CorrelationId = correlationId,
            RequestId = request.RequestId,
            TicketNumber = request.TicketNumber,
            AssetId = request.AssetId,
            Action = "RequestReceived",
            Actor = request.Requestor ?? "servicenow",
            Outcome = "Accepted",
            Reason = request.DryRun ? "dry-run" : null
        }, ct);

        await _workflow.StartAsync(request.RequestId, correlationId, ct);

        return new IntakeResult(true, true, correlationId, null);
    }

    private static string? Validate(DecommissionRequest r)
    {
        if (string.IsNullOrWhiteSpace(r.RequestId))
            return "requestId is required.";
        if (string.IsNullOrWhiteSpace(r.AssetId))
            return "assetId is required.";
        if (r.RequestedActions is null || r.RequestedActions.Count == 0)
            return "requestedActions must contain at least one action.";
        if (string.IsNullOrWhiteSpace(r.DeviceName) && string.IsNullOrWhiteSpace(r.SerialNumber))
            return "deviceName or serialNumber is required to locate the device.";
        if (!Enum.IsDefined(r.DeviceType))
            return "deviceType is invalid.";
        return null;
    }
}
