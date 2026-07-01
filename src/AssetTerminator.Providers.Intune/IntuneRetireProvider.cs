using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using Microsoft.Graph.Models;

namespace AssetTerminator.Providers.Intune;

/// <summary>
/// Issues an Intune retire (remove company data / management while keeping the device usable) for a
/// re-purpose disposition, and verifies its asynchronous completion over time.
/// </summary>
public sealed class IntuneRetireProvider : IRetireProvider
{
    private readonly GraphIntuneService _intune;

    public IntuneRetireProvider(GraphIntuneService intune)
    {
        _intune = intune;
    }

    public async Task<ProviderResult> RetireAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var id = await _intune.ResolveManagedDeviceIdAsync(context, ct).ConfigureAwait(false);
            if (id is null)
            {
                return ProviderResult.Skipped("not present in Intune");
            }

            await _intune.RetireAsync(id, ct).ConfigureAwait(false);
            return ProviderResult.Success($"issued Intune retire for managedDevice {id}");
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

    public async Task<ProviderResult> GetRetireStatusAsync(DeviceContext context, CancellationToken ct)
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

            // The retire is asynchronous; look for the retire device action reaching a terminal state.
            var retireAction = device.DeviceActionResults?
                .OrderByDescending(result => result.LastUpdatedDateTime ?? result.StartDateTime)
                .FirstOrDefault(result => string.Equals(result.ActionName, "retire", StringComparison.OrdinalIgnoreCase));

            if (retireAction?.ActionState == ActionState.Done)
            {
                return ProviderResult.Success("Intune retire completed");
            }

            return ProviderResult.Failed("retire pending / device offline", transient: true);
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
