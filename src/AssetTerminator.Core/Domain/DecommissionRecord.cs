using AssetTerminator.Contracts;

namespace AssetTerminator.Core.Domain;

/// <summary>
/// Persisted current-state record for a decommission request (transactional store).
/// This is the mutable, real-time state — never the immutable audit.
/// </summary>
public sealed class DecommissionRecord
{
    public required string RequestId { get; set; }
    public required string CorrelationId { get; set; }
    public string AssetId { get; set; } = string.Empty;
    public string? DeviceName { get; set; }
    public string? SerialNumber { get; set; }
    public string? PrimaryUserUpn { get; set; }
    public DeviceType DeviceType { get; set; }
    public AssetCategory AssetCategory { get; set; }
    public string? TicketNumber { get; set; }
    public string? Requestor { get; set; }
    public bool DryRun { get; set; }

    public RequestState State { get; set; } = RequestState.Requested;
    public SlaState SlaState { get; set; } = SlaState.WithinSla;

    public DateTimeOffset CreatedAtUtc { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset LastUpdatedAtUtc { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>Deadline after which the request is given up (TimedOut).</summary>
    public DateTimeOffset DueAtUtc { get; set; }

    /// <summary>Raw inbound request JSON, for full fidelity replay.</summary>
    public string RequestJson { get; set; } = string.Empty;

    /// <summary>Serialized enriched <see cref="DeviceContext"/> (resolved ids, encryption state, ...).</summary>
    public string? DeviceContextJson { get; set; }

    public List<SubAction> Actions { get; set; } = new();
}

/// <summary>
/// Persisted current-state record for a single sub-action.
/// </summary>
public sealed class SubAction
{
    public long Id { get; set; }
    public required string RequestId { get; set; }
    public DecommissionTarget Target { get; set; }
    public string Action { get; set; } = string.Empty;
    public ActionStatus Status { get; set; } = ActionStatus.Pending;
    public int RetryCount { get; set; }
    public DateTimeOffset? LastCheckedUtc { get; set; }
    public DateTimeOffset? NextAttemptUtc { get; set; }
    public string? FinalOutcome { get; set; }
    public string? Details { get; set; }
}
