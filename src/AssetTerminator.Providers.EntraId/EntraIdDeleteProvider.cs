using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;

namespace AssetTerminator.Providers.EntraId;

public sealed class EntraIdDeleteProvider : IDeviceCleanupProvider
{
    private readonly GraphEntraDeviceService _entra;

    public EntraIdDeleteProvider(GraphEntraDeviceService entra)
    {
        _entra = entra;
    }

    public DecommissionTarget Target => DecommissionTarget.EntraId;

    public async Task<bool> ExistsAsync(DeviceContext context, CancellationToken ct)
    {
        var objectId = await _entra.ResolveDeviceObjectIdAsync(context, ct).ConfigureAwait(false);
        return objectId is not null && await _entra.ExistsAsync(objectId, ct).ConfigureAwait(false);
    }

    public async Task<ProviderResult> DeleteAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var objectId = await _entra.ResolveDeviceObjectIdAsync(context, ct).ConfigureAwait(false);
            if (objectId is null)
            {
                return ProviderResult.Skipped("not present in Entra ID");
            }

            await _entra.DeleteDeviceAsync(objectId, ct).ConfigureAwait(false);
            return ProviderResult.Success($"deleted Entra device object {objectId}");
        }
        catch (GraphEntraDeviceServiceException ex) when (ex.NotFound)
        {
            return ProviderResult.Skipped("not present in Entra ID");
        }
        catch (GraphEntraDeviceServiceException ex)
        {
            return ProviderResult.Failed(ex.Message, ex.Transient);
        }
    }

    public async Task<ProviderResult> GetStatusAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var objectId = await _entra.ResolveDeviceObjectIdAsync(context, ct).ConfigureAwait(false);
            if (objectId is null || !await _entra.ExistsAsync(objectId, ct).ConfigureAwait(false))
            {
                return ProviderResult.Success("not present in Entra ID");
            }

            return ProviderResult.Failed($"Entra device object still present: {objectId}", transient: true);
        }
        catch (GraphEntraDeviceServiceException ex) when (ex.NotFound)
        {
            return ProviderResult.Success("not present in Entra ID");
        }
        catch (GraphEntraDeviceServiceException ex)
        {
            return ProviderResult.Failed(ex.Message, ex.Transient);
        }
    }
}
