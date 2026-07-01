using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;

namespace AssetTerminator.Providers.Intune;

/// <summary>
/// Deletes the device's Windows Autopilot registration. For a Terminate disposition this must
/// run before the Intune wipe so the hardware hash is de-registered ahead of the reset.
/// </summary>
public sealed class AutopilotDeleteProvider : IDeviceCleanupProvider
{
    private readonly GraphIntuneService _intune;

    public AutopilotDeleteProvider(GraphIntuneService intune)
    {
        _intune = intune;
    }

    public DecommissionTarget Target => DecommissionTarget.Autopilot;

    public async Task<bool> ExistsAsync(DeviceContext context, CancellationToken ct) =>
        await _intune.ResolveAutopilotIdentityIdAsync(context, ct).ConfigureAwait(false) is not null;

    public async Task<ProviderResult> DeleteAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var id = await _intune.ResolveAutopilotIdentityIdAsync(context, ct).ConfigureAwait(false);
            if (id is null)
            {
                return ProviderResult.Skipped("not registered in Autopilot");
            }

            await _intune.DeleteAutopilotIdentityAsync(id, ct).ConfigureAwait(false);
            return ProviderResult.Success($"deleted Autopilot identity {id}");
        }
        catch (GraphIntuneServiceException ex) when (ex.NotFound)
        {
            return ProviderResult.Skipped("not registered in Autopilot");
        }
        catch (GraphIntuneServiceException ex)
        {
            return ProviderResult.Failed(ex.Message, ex.Transient);
        }
    }

    public async Task<ProviderResult> GetStatusAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var id = await _intune.ResolveAutopilotIdentityIdAsync(context, ct).ConfigureAwait(false);
            return id is null
                ? ProviderResult.Success("not registered in Autopilot")
                : ProviderResult.Failed($"Autopilot identity still present: {id}", transient: true);
        }
        catch (GraphIntuneServiceException ex) when (ex.NotFound)
        {
            return ProviderResult.Success("not registered in Autopilot");
        }
        catch (GraphIntuneServiceException ex)
        {
            return ProviderResult.Failed(ex.Message, ex.Transient);
        }
    }
}
