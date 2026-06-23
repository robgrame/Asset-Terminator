using AssetTerminator.Core.Abstractions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace AssetTerminator.Providers.ActiveDirectory;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddActiveDirectoryProvider(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddOptions<ActiveDirectoryOptions>()
            .Bind(configuration.GetSection(ActiveDirectoryOptions.Section));

        services.AddSingleton<LdapComputerDirectory>();
        services.AddSingleton<IDeviceCleanupProvider, ActiveDirectoryCleanupProvider>();

        return services;
    }
}
