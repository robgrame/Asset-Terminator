using AssetTerminator.Contracts;

namespace AssetTerminator.Core.Domain;

/// <summary>
/// Read model describing the device under decommission. Built by the orchestrator
/// from the inbound request enriched with live signals (encryption state, last
/// activity, group membership) gathered from Intune/Entra. Passed to guardrails.
/// </summary>
public sealed class DeviceContext
{
    public required string RequestId { get; init; }
    public required string CorrelationId { get; init; }
    public string? DeviceName { get; init; }
    public string? SerialNumber { get; init; }
    public string? PrimaryUserUpn { get; init; }
    public DeviceType DeviceType { get; init; }
    public AssetCategory AssetCategory { get; init; }

    /// <summary>Intune managedDevice id, resolved during enrichment.</summary>
    public string? IntuneManagedDeviceId { get; set; }

    /// <summary>Entra device object id, resolved during enrichment.</summary>
    public string? EntraDeviceId { get; set; }

    /// <summary>True when disk encryption is reported as enabled (BitLocker/FileVault).</summary>
    public bool? IsEncrypted { get; set; }

    /// <summary>True when a BitLocker recovery key is escrowed (Windows).</summary>
    public bool? HasRecoveryKeyEscrowed { get; set; }

    /// <summary>Last time the device checked in / was active.</summary>
    public DateTimeOffset? LastActivityUtc { get; set; }

    /// <summary>True when the primary user account is disabled in Entra.</summary>
    public bool? PrimaryUserDisabled { get; set; }

    /// <summary>Entra group display names the device belongs to.</summary>
    public IReadOnlyList<string> GroupMemberships { get; set; } = Array.Empty<string>();

    /// <summary>Free-form enrichment signals for custom guardrails.</summary>
    public Dictionary<string, string?> Signals { get; } = new(StringComparer.OrdinalIgnoreCase);
}
