using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;

namespace AssetTerminator.Providers.Intune;

public sealed class IntuneDeleteProvider : IDeviceCleanupProvider
{
    private readonly GraphIntuneService _intune;

    public IntuneDeleteProvider(GraphIntuneService intune)
    {
        _intune = intune;
    }

    public DecommissionTarget Target => DecommissionTarget.Intune;

    public async Task<bool> ExistsAsync(DeviceContext context, CancellationToken ct) =>
        await _intune.ResolveManagedDeviceIdAsync(context, ct).ConfigureAwait(false) is not null;

    public async Task<ProviderResult> DeleteAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var id = await _intune.ResolveManagedDeviceIdAsync(context, ct).ConfigureAwait(false);
            if (id is null)
            {
                return ProviderResult.Skipped("not present in Intune");
            }

            await _intune.DeleteManagedDeviceAsync(id, ct).ConfigureAwait(false);
            return ProviderResult.Success($"deleted Intune managedDevice {id}");
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

    public async Task<ProviderResult> GetStatusAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var id = await _intune.ResolveManagedDeviceIdAsync(context, ct).ConfigureAwait(false);
            if (id is null)
            {
                return ProviderResult.Success("not present in Intune");
            }

            var device = await _intune.GetManagedDeviceAsync(id, ct).ConfigureAwait(false);
            return device is null
                ? ProviderResult.Success("not present in Intune")
                : ProviderResult.Failed($"Intune managedDevice still present: {id}", transient: true);
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
