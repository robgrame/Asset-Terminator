namespace AssetTerminator.Contracts;

/// <summary>
/// Lightweight, serialization-friendly projection of a decommission request state change,
/// pushed to the realtime operations board (Event Grid -&gt; SignalR). Intentionally decoupled
/// from the domain model so the web/functions tier does not depend on Core.
/// </summary>
public sealed record RealtimeStateChange
{
    public required string RequestId { get; init; }
    public string? CorrelationId { get; init; }
    public string? AssetId { get; init; }
    public string? DeviceName { get; init; }
    public string? TicketNumber { get; init; }

    /// <summary>Current overall request state (e.g. Requested/InProgress/Completed/Failed).</summary>
    public required string OverallStatus { get; init; }

    public string? DeviceType { get; init; }
    public string? AssetCategory { get; init; }
    public string? DispositionType { get; init; }
    public string? SlaState { get; init; }
    public bool DryRun { get; init; }

    public DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset UpdatedAt { get; init; }
    public DateTimeOffset? DueAt { get; init; }

    /// <summary>True when the request reached a terminal state.</summary>
    public bool Terminal { get; init; }
}
