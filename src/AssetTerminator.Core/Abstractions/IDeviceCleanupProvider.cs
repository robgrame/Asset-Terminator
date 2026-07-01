using AssetTerminator.Contracts;
using AssetTerminator.Core.Domain;

namespace AssetTerminator.Core.Abstractions;

/// <summary>
/// Result of a provider operation against one management environment.
/// </summary>
public sealed class ProviderResult
{
    public ActionStatus Status { get; init; }
    public string? Detail { get; init; }

    /// <summary>True when the failure is transient and the action should be retried.</summary>
    public bool Transient { get; init; }

    public static ProviderResult Success(string? detail = null) =>
        new() { Status = ActionStatus.Success, Detail = detail };

    public static ProviderResult Skipped(string detail) =>
        new() { Status = ActionStatus.Skipped, Detail = detail };

    public static ProviderResult Failed(string detail, bool transient) =>
        new() { Status = ActionStatus.Failed, Detail = detail, Transient = transient };
}

/// <summary>
/// Common interface for every management environment connector
/// (AD, SCCM, Intune, Entra ID). Implementations are independent and never abort
/// the whole flow; the orchestrator aggregates their results.
/// </summary>
public interface IDeviceCleanupProvider
{
    /// <summary>The environment this provider cleans up.</summary>
    DecommissionTarget Target { get; }

    /// <summary>Whether the device object currently exists in this environment.</summary>
    Task<bool> ExistsAsync(DeviceContext context, CancellationToken ct);

    /// <summary>Delete the device object from this environment (honors dry-run upstream).</summary>
    Task<ProviderResult> DeleteAsync(DeviceContext context, CancellationToken ct);

    /// <summary>Re-check the live status (used by the polling engine over time).</summary>
    Task<ProviderResult> GetStatusAsync(DeviceContext context, CancellationToken ct);
}

/// <summary>
/// Specialised provider that issues the Intune wipe and verifies its asynchronous
/// completion over time (device may be offline for days).
/// </summary>
public interface IWipeProvider
{
    /// <summary>Issue the wipe command for the device.</summary>
    Task<ProviderResult> WipeAsync(DeviceContext context, CancellationToken ct);

    /// <summary>
    /// Verify wipe completion: success when the device is gone or Graph reports the
    /// wipe complete; otherwise still pending. Used by the polling engine.
    /// </summary>
    Task<ProviderResult> GetWipeStatusAsync(DeviceContext context, CancellationToken ct);
}

/// <summary>
/// Specialised provider that issues the Intune retire (remove company data / management while
/// keeping the device usable) for a re-purpose disposition, and verifies its completion over time.
/// </summary>
public interface IRetireProvider
{
    /// <summary>Issue the retire command for the device.</summary>
    Task<ProviderResult> RetireAsync(DeviceContext context, CancellationToken ct);

    /// <summary>
    /// Verify retire completion: success when Graph reports the retire done or the device is
    /// no longer managed; otherwise still pending. Used by the polling engine.
    /// </summary>
    Task<ProviderResult> GetRetireStatusAsync(DeviceContext context, CancellationToken ct);
}
