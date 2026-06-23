using System.Text.Json.Serialization;

namespace AssetTerminator.Contracts;

/// <summary>
/// Synchronous response returned to ServiceNow on intake (HTTP 202).
/// </summary>
public sealed class DecommissionAccepted
{
    [JsonPropertyName("requestId")]
    public string RequestId { get; set; } = string.Empty;

    /// <summary>Server-generated correlation id used to track the workflow end-to-end.</summary>
    [JsonPropertyName("correlationId")]
    public string CorrelationId { get; set; } = string.Empty;

    [JsonPropertyName("status")]
    public string Status { get; set; } = "Accepted";

    [JsonPropertyName("statusUrl")]
    public string? StatusUrl { get; set; }
}

/// <summary>
/// Status of a single decommission sub-action, as returned by query endpoints.
/// </summary>
public sealed class DecommissionActionStatus
{
    [JsonPropertyName("target")]
    public DecommissionTarget Target { get; set; }

    [JsonPropertyName("action")]
    public string Action { get; set; } = string.Empty;

    [JsonPropertyName("status")]
    public string Status { get; set; } = string.Empty;

    [JsonPropertyName("lastChecked")]
    public DateTimeOffset? LastChecked { get; set; }

    [JsonPropertyName("retryCount")]
    public int RetryCount { get; set; }

    [JsonPropertyName("details")]
    public string? Details { get; set; }
}

/// <summary>
/// Aggregate status of a decommission request (GET /{requestId}).
/// </summary>
public sealed class DecommissionStatusResponse
{
    [JsonPropertyName("requestId")]
    public string RequestId { get; set; } = string.Empty;

    [JsonPropertyName("correlationId")]
    public string CorrelationId { get; set; } = string.Empty;

    [JsonPropertyName("ticketNumber")]
    public string? TicketNumber { get; set; }

    [JsonPropertyName("overallStatus")]
    public string OverallStatus { get; set; } = string.Empty;

    [JsonPropertyName("slaState")]
    public string? SlaState { get; set; }

    [JsonPropertyName("createdAt")]
    public DateTimeOffset CreatedAt { get; set; }

    [JsonPropertyName("lastUpdatedAt")]
    public DateTimeOffset LastUpdatedAt { get; set; }

    [JsonPropertyName("dueAt")]
    public DateTimeOffset? DueAt { get; set; }

    [JsonPropertyName("actions")]
    public List<DecommissionActionStatus> Actions { get; set; } = new();
}

/// <summary>
/// A single immutable timeline event (GET /{requestId}/history).
/// </summary>
public sealed class DecommissionHistoryEvent
{
    [JsonPropertyName("timestamp")]
    public DateTimeOffset Timestamp { get; set; }

    [JsonPropertyName("eventType")]
    public string EventType { get; set; } = string.Empty;

    [JsonPropertyName("target")]
    public string? Target { get; set; }

    [JsonPropertyName("outcome")]
    public string? Outcome { get; set; }

    [JsonPropertyName("actor")]
    public string? Actor { get; set; }

    [JsonPropertyName("detail")]
    public string? Detail { get; set; }
}
