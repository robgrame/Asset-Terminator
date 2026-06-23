using System.Net;
using AssetTerminator.Core.Abstractions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Providers.ConfigMgr;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddConfigMgrProvider(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddOptions<ConfigMgrOptions>()
            .Bind(configuration.GetSection(ConfigMgrOptions.Section));

        services.AddHttpClient<SccmAdminService>((sp, client) =>
            {
                var options = sp.GetRequiredService<IOptions<ConfigMgrOptions>>().Value;
                if (!string.IsNullOrWhiteSpace(options.AdminServiceBaseUrl))
                {
                    client.BaseAddress = new Uri(EnsureTrailingSlash(options.AdminServiceBaseUrl));
                }
            })
            .ConfigurePrimaryHttpMessageHandler(sp =>
            {
                var options = sp.GetRequiredService<IOptions<ConfigMgrOptions>>().Value;
                var handler = new HttpClientHandler();

                if (options.AuthMode.Equals("windows", StringComparison.OrdinalIgnoreCase))
                {
                    handler.UseDefaultCredentials = string.IsNullOrWhiteSpace(options.Username);
                    if (!string.IsNullOrWhiteSpace(options.Username))
                    {
                        handler.Credentials = new NetworkCredential(options.Username, options.Password);
                    }
                }

                return handler;
            });

        services.AddTransient<IDeviceCleanupProvider, ConfigMgrCleanupProvider>();

        return services;
    }

    private static string EnsureTrailingSlash(string value) =>
        value.EndsWith("/", StringComparison.Ordinal) ? value : value + "/";
}
