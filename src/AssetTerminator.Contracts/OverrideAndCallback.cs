using System.Text.Json.Serialization;

namespace AssetTerminator.Contracts;

/// <summary>
/// Request body for a guardrail override (POST /{requestId}/override).
/// </summary>
public sealed class OverrideRequest
{
    /// <summary>Mandatory justification for the override. Persisted in the immutable audit.</summary>
    [JsonPropertyName("reason")]
    public string Reason { get; set; } = string.Empty;

    /// <summary>
    /// Optional list of specific guardrail ids to bypass. When empty, all currently
    /// failing guardrails that are configured as overridable are bypassed.
    /// </summary>
    [JsonPropertyName("guardrailIds")]
    public List<string> GuardrailIds { get; set; } = new();
}

/// <summary>
/// Push notification payload delivered to ServiceNow (callback model).
/// </summary>
public sealed class ServiceNowCallback
{
    /// <summary>Unique id of this callback event; enables idempotent processing on the ServiceNow side.</summary>
    [JsonPropertyName("eventId")]
    public string EventId { get; set; } = Guid.NewGuid().ToString();

    [JsonPropertyName("requestId")]
    public string RequestId { get; set; } = string.Empty;

    [JsonPropertyName("correlationId")]
    public string CorrelationId { get; set; } = string.Empty;

    [JsonPropertyName("ticketNumber")]
    public string? TicketNumber { get; set; }

    /// <summary>Completed | Failed | InProgress | TimedOut | Blocked | SlaBreached | SlaAtRisk.</summary>
    [JsonPropertyName("overallStatus")]
    public string OverallStatus { get; set; } = string.Empty;

    [JsonPropertyName("eventType")]
    public string EventType { get; set; } = string.Empty;

    [JsonPropertyName("timestamp")]
    public DateTimeOffset Timestamp { get; set; } = DateTimeOffset.UtcNow;

    [JsonPropertyName("details")]
    public Dictionary<string, object?> Details { get; set; } = new();
}
