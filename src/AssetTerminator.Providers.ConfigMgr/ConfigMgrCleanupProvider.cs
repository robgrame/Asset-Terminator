using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Providers.ConfigMgr;

public sealed class ConfigMgrCleanupProvider : IDeviceCleanupProvider
{
    private readonly SccmAdminService _adminService;
    private readonly ConfigMgrOptions _options;

    public ConfigMgrCleanupProvider(SccmAdminService adminService, IOptions<ConfigMgrOptions> options)
    {
        _adminService = adminService;
        _options = options.Value;
    }

    public DecommissionTarget Target => DecommissionTarget.ConfigMgr;

    public async Task<bool> ExistsAsync(DeviceContext context, CancellationToken ct) =>
        await _adminService.FindDeviceResourceIdAsync(context.DeviceName, context.SerialNumber, ct).ConfigureAwait(false) is not null;

    public async Task<ProviderResult> DeleteAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var resourceId = await _adminService.FindDeviceResourceIdAsync(context.DeviceName, context.SerialNumber, ct).ConfigureAwait(false);
            if (resourceId is null)
            {
                return ProviderResult.Skipped("device not found in ConfigMgr");
            }

            if (_options.DryRun)
            {
                return ProviderResult.Success($"[DRY-RUN] would delete resourceId {resourceId}");
            }

            await _adminService.DeleteDeviceAsync(resourceId.Value, ct).ConfigureAwait(false);
            return ProviderResult.Success($"deleted resourceId {resourceId}");
        }
        catch (SccmAdminServiceException ex) when (ex.NotFound)
        {
            return ProviderResult.Skipped("device not found in ConfigMgr");
        }
        catch (SccmAdminServiceException ex)
        {
            return ProviderResult.Failed(ex.Message, ex.Transient);
        }
    }

    public async Task<ProviderResult> GetStatusAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var resourceId = await _adminService.FindDeviceResourceIdAsync(context.DeviceName, context.SerialNumber, ct).ConfigureAwait(false);
            return resourceId is null
                ? ProviderResult.Success("device not found in ConfigMgr")
                : ProviderResult.Failed($"device still exists in ConfigMgr: resourceId {resourceId}", transient: true);
        }
        catch (SccmAdminServiceException ex) when (ex.NotFound)
        {
            return ProviderResult.Success("device not found in ConfigMgr");
        }
        catch (SccmAdminServiceException ex)
        {
            return ProviderResult.Failed(ex.Message, ex.Transient);
        }
    }
}
