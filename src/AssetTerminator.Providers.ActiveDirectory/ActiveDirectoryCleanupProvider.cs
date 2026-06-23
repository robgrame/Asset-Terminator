using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Providers.ActiveDirectory;

public sealed class ActiveDirectoryCleanupProvider : IDeviceCleanupProvider
{
    private readonly LdapComputerDirectory _directory;
    private readonly ActiveDirectoryOptions _options;

    public ActiveDirectoryCleanupProvider(LdapComputerDirectory directory, IOptions<ActiveDirectoryOptions> options)
    {
        _directory = directory;
        _options = options.Value;
    }

    public DecommissionTarget Target => DecommissionTarget.ActiveDirectory;

    public async Task<bool> ExistsAsync(DeviceContext context, CancellationToken ct) =>
        await _directory.FindComputerDnAsync(context.DeviceName, ct).ConfigureAwait(false) is not null;

    public async Task<ProviderResult> DeleteAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var dn = await _directory.FindComputerDnAsync(context.DeviceName, ct).ConfigureAwait(false);
            if (dn is null)
            {
                return ProviderResult.Skipped("computer not found in AD");
            }

            if (_options.DryRun)
            {
                return ProviderResult.Success($"[DRY-RUN] would delete {dn}");
            }

            await _directory.DeleteComputerAsync(dn, ct).ConfigureAwait(false);
            return ProviderResult.Success($"deleted {dn}");
        }
        catch (LdapComputerDirectoryException ex) when (ex.NotFound)
        {
            return ProviderResult.Skipped("computer not found in AD");
        }
        catch (LdapComputerDirectoryException ex)
        {
            return ProviderResult.Failed(ex.Message, ex.Transient);
        }
    }

    public async Task<ProviderResult> GetStatusAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var dn = await _directory.FindComputerDnAsync(context.DeviceName, ct).ConfigureAwait(false);
            return dn is null
                ? ProviderResult.Success("computer not found in AD")
                : ProviderResult.Failed($"computer still exists in AD: {dn}", transient: true);
        }
        catch (LdapComputerDirectoryException ex) when (ex.NotFound)
        {
            return ProviderResult.Success("computer not found in AD");
        }
        catch (LdapComputerDirectoryException ex)
        {
            return ProviderResult.Failed(ex.Message, ex.Transient);
        }
    }
}
