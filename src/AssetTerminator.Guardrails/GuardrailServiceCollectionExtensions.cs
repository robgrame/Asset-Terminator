using AssetTerminator.Core.Guardrails;
using AssetTerminator.Core.Options;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace AssetTerminator.Guardrails;

public static class GuardrailServiceCollectionExtensions
{
    public static IServiceCollection AddGuardrails(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<GuardrailsOptions>(configuration.GetSection(GuardrailsOptions.Section));

        services.AddSingleton<IGuardrailEngine, GuardrailEngine>();
        services.AddSingleton<IWipeGuardrail, EncryptionGuardrail>();
        services.AddSingleton<IWipeGuardrail, InactivityGuardrail>();
        services.AddSingleton<IWipeGuardrail, CriticalGroupGuardrail>();

        return services;
    }
}
