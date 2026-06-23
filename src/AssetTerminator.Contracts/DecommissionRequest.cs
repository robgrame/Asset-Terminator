using System.Text.Json.Serialization;

namespace AssetTerminator.Contracts;

/// <summary>
/// Inbound decommission request sent by ServiceNow.
/// <para>
/// <see cref="RequestId"/> is the idempotency key: the same value must never
/// trigger a second execution.
/// </para>
/// </summary>
public sealed class DecommissionRequest
{
    /// <summary>Idempotency key supplied by ServiceNow (e.g. the change/task sys_id).</summary>
    [JsonPropertyName("requestId")]
    public string RequestId { get; set; } = string.Empty;

    /// <summary>CMDB asset identifier.</summary>
    [JsonPropertyName("assetId")]
    public string AssetId { get; set; } = string.Empty;

    /// <summary>Device (computer) name as known to AD/SCCM/Intune.</summary>
    [JsonPropertyName("deviceName")]
    public string? DeviceName { get; set; }

    /// <summary>Hardware serial number (used as a secondary correlation key).</summary>
    [JsonPropertyName("serialNumber")]
    public string? SerialNumber { get; set; }

    /// <summary>Primary user UPN.</summary>
    [JsonPropertyName("primaryUserUpn")]
    public string? PrimaryUserUpn { get; set; }

    /// <summary>Device platform.</summary>
    [JsonPropertyName("deviceType")]
    public DeviceType DeviceType { get; set; }

    /// <summary>Business classification used for SLA and approval routing.</summary>
    [JsonPropertyName("assetCategory")]
    public AssetCategory AssetCategory { get; set; } = AssetCategory.Standard;

    /// <summary>Requested actions, executed in a controlled order by the orchestrator.</summary>
    [JsonPropertyName("requestedActions")]
    public List<DecommissionTarget> RequestedActions { get; set; } = new();

    /// <summary>Identity of the requestor (ServiceNow user).</summary>
    [JsonPropertyName("requestor")]
    public string? Requestor { get; set; }

    /// <summary>ServiceNow ticket / change number for traceability.</summary>
    [JsonPropertyName("ticketNumber")]
    public string? TicketNumber { get; set; }

    /// <summary>Request creation timestamp (UTC) as recorded by ServiceNow.</summary>
    [JsonPropertyName("timestamp")]
    public DateTimeOffset? Timestamp { get; set; }

    /// <summary>
    /// When true, the orchestrator evaluates everything (including guardrails)
    /// but performs no destructive delete/wipe. Used for safe simulation.
    /// </summary>
    [JsonPropertyName("dryRun")]
    public bool DryRun { get; set; }
}
