using AssetTerminator.Core.Abstractions;
using Microsoft.Extensions.DependencyInjection;

namespace AssetTerminator.Providers.Intune;

public static class IntuneProvidersExtensions
{
    public static IServiceCollection AddIntuneProviders(this IServiceCollection services)
    {
        services.AddTransient<GraphIntuneService>();
        services.AddTransient<IDeviceCleanupProvider, IntuneDeleteProvider>();
        services.AddTransient<IWipeProvider, IntuneWipeProvider>();

        return services;
    }
}
