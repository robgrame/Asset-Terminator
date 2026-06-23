using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using Microsoft.Graph.Models;

namespace AssetTerminator.Providers.Intune;

public sealed class IntuneWipeProvider : IWipeProvider
{
    private readonly GraphIntuneService _intune;

    public IntuneWipeProvider(GraphIntuneService intune)
    {
        _intune = intune;
    }

    public async Task<ProviderResult> WipeAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var id = await _intune.ResolveManagedDeviceIdAsync(context, ct).ConfigureAwait(false);
            if (id is null)
            {
                return ProviderResult.Skipped("not present in Intune");
            }

            await _intune.WipeAsync(id, context.DeviceType, ct).ConfigureAwait(false);
            return ProviderResult.Success($"issued Intune wipe for managedDevice {id}");
        }
        catch (GraphIntuneServiceException ex) when (ex.NotFound)
        {
            return ProviderResult.Skipped("not present in Intune");
        }
        catch (GraphIntuneServiceException ex)
        {
            return ProviderResult.Failed(ex.Message, ex.Transient);
        }
    }

    public async Task<ProviderResult> GetWipeStatusAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var id = await _intune.ResolveManagedDeviceIdAsync(context, ct).ConfigureAwait(false);
            if (id is null)
            {
                return ProviderResult.Success("not present in Intune");
            }

            var device = await _intune.GetManagedDeviceAsync(id, ct).ConfigureAwait(false);
            if (device is null)
            {
                return ProviderResult.Success("not present in Intune");
            }

            if (device.ManagementState == ManagementState.WipeFailed)
            {
                return ProviderResult.Failed("Intune wipe failed", transient: false);
            }

            // TODO: Confirm the exact deviceActionResults action name Graph emits for tenant wipe commands.
            var wipeAction = device.DeviceActionResults?
                .OrderByDescending(result => result.LastUpdatedDateTime ?? result.StartDateTime)
                .FirstOrDefault(result => string.Equals(result.ActionName, "wipe", StringComparison.OrdinalIgnoreCase));

            if (wipeAction?.ActionState == ActionState.Done)
            {
                return ProviderResult.Success("Intune wipe completed");
            }

            return ProviderResult.Failed("wipe pending / device offline", transient: true);
        }
        catch (GraphIntuneServiceException ex) when (ex.NotFound)
        {
            return ProviderResult.Success("not present in Intune");
        }
        catch (GraphIntuneServiceException ex)
        {
            return ProviderResult.Failed(ex.Message, ex.Transient);
        }
    }
}
