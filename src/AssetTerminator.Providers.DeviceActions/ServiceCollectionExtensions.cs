using AssetTerminator.Core.Abstractions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace AssetTerminator.Providers.DeviceActions;

public static class ServiceCollectionExtensions
{
    /// <summary>
    /// Registers the on-device preventive-action providers (Enterprise license removal and BIOS
    /// password removal) executed by the on-prem agent before a wipe.
    /// </summary>
    public static IServiceCollection AddDeviceActionsProviders(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddOptions<DeviceActionsOptions>()
            .Bind(configuration.GetSection(DeviceActionsOptions.Section));

        services.AddSingleton<ILocalCommandRunner, ProcessCommandRunner>();
        services.AddSingleton<IDeviceCleanupProvider, LicenseRemovalProvider>();
        services.AddSingleton<IDeviceCleanupProvider, BiosPasswordRemovalProvider>();

        return services;
    }
}
