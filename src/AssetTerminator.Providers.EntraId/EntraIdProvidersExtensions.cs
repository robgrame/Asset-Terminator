using AssetTerminator.Core.Abstractions;
using Microsoft.Extensions.DependencyInjection;

namespace AssetTerminator.Providers.EntraId;

public static class EntraIdProvidersExtensions
{
    public static IServiceCollection AddEntraIdProviders(this IServiceCollection services)
    {
        services.AddTransient<GraphEntraDeviceService>();
        services.AddTransient<IDeviceCleanupProvider, EntraIdDeleteProvider>();

        return services;
    }
}
