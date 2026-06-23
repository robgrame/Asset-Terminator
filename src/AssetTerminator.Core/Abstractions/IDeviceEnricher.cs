using AssetTerminator.Core.Domain;

namespace AssetTerminator.Core.Abstractions;

/// <summary>
/// Enriches a <see cref="DeviceContext"/> with live signals required by guardrails and
/// providers: resolved Intune/Entra ids, encryption state (BitLocker/FileVault),
/// recovery-key escrow, last activity, primary-user status, and group memberships.
/// </summary>
public interface IDeviceEnricher
{
    Task EnrichAsync(DeviceContext context, CancellationToken ct);
}
