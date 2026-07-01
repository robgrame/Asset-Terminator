using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Azure.Monitor.Ingestion;
using Azure.Security.KeyVault.Secrets;
using Azure.Storage.Blobs;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Options;
using AssetTerminator.Infrastructure.Audit;
using AssetTerminator.Infrastructure.Callbacks;
using AssetTerminator.Infrastructure.Data;
using AssetTerminator.Infrastructure.Messaging;
using AssetTerminator.Infrastructure.Observability;
using AssetTerminator.Infrastructure.Secrets;
using AssetTerminator.Infrastructure.Sla;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace AssetTerminator.Infrastructure.DependencyInjection;

/// <summary>
/// Composition root for the shared infrastructure (state store, audit, messaging,
/// callbacks, SLA). Hosts call <see cref="AddAssetTerminatorInfrastructure"/> and then
/// add their own capability/provider registrations.
/// </summary>
public static class InfrastructureServiceCollectionExtensions
{
    public static IServiceCollection AddAssetTerminatorInfrastructure(
        this IServiceCollection services, IConfiguration configuration)
    {
        BindOptions(services, configuration);

        var credential = new DefaultAzureCredential();

        // --- Current-state store (Azure SQL serverless) ---
        var sqlConnection = configuration.GetConnectionString("StateStore")
            ?? configuration["AssetTerminator:StateStore:ConnectionString"];
        services.AddDbContext<AssetTerminatorDbContext>(o =>
        {
            if (!string.IsNullOrWhiteSpace(sqlConnection))
                o.UseSqlServer(sqlConnection, sql => sql.EnableRetryOnFailure());
        });
        services.AddScoped<IStateStore, SqlStateStore>();

        // --- Immutable audit (Blob WORM) ---
        var auditOptions = configuration.GetSection(AuditOptions.Section).Get<AuditOptions>() ?? new AuditOptions();
        services.AddSingleton(_ =>
        {
            var service = new BlobServiceClient(new Uri(auditOptions.BlobServiceUri!), credential);
            return service.GetBlobContainerClient(auditOptions.ContainerName);
        });
        services.AddSingleton<IAuditWriter, BlobAuditWriter>();

        // --- Messaging (Service Bus) ---
        var messaging = configuration.GetSection(MessagingOptions.Section).Get<MessagingOptions>() ?? new MessagingOptions();
        services.AddSingleton(_ => new ServiceBusClient(messaging.FullyQualifiedNamespace, credential));
        services.AddSingleton<IActionDispatcher, ServiceBusActionDispatcher>();
        services.AddSingleton<IWorkflowStarter, ServiceBusWorkflowStarter>();

        // --- Secrets (Key Vault) ---
        var keyVaultUri = configuration["AssetTerminator:KeyVaultUri"];
        if (!string.IsNullOrWhiteSpace(keyVaultUri))
            services.AddSingleton(_ => new SecretClient(new Uri(keyVaultUri), credential));
        services.AddSingleton<ISecretResolver, KeyVaultSecretResolver>();

        // --- SLA ---
        services.AddSingleton<ISlaCalculator, SlaCalculator>();

        // --- Operational telemetry (Log Analytics custom tables via Logs Ingestion) ---
        var observability = configuration.GetSection(ObservabilityOptions.Section).Get<ObservabilityOptions>() ?? new ObservabilityOptions();
        if (!string.IsNullOrWhiteSpace(observability.DcrEndpoint) && !string.IsNullOrWhiteSpace(observability.DcrImmutableId))
        {
            services.AddSingleton(_ => new LogsIngestionClient(new Uri(observability.DcrEndpoint), credential));
            services.AddSingleton<IOperationalTelemetry, LogsIngestionTelemetry>();
        }
        else
        {
            services.AddSingleton<IOperationalTelemetry>(NullOperationalTelemetry.Instance);
        }

        // --- ServiceNow callbacks ---
        services.AddHttpClient<ICallbackSender, HttpServiceNowCallbackSender>();

        return services;
    }

    private static void BindOptions(IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<IngestionOptions>(configuration.GetSection(IngestionOptions.Section));
        services.Configure<GuardrailsOptions>(configuration.GetSection(GuardrailsOptions.Section));
        services.Configure<SlaOptions>(configuration.GetSection(SlaOptions.Section));
        services.Configure<CallbackOptions>(configuration.GetSection(CallbackOptions.Section));
        services.Configure<AuditOptions>(configuration.GetSection(AuditOptions.Section));
        services.Configure<OrchestrationOptions>(configuration.GetSection(OrchestrationOptions.Section));
        services.Configure<PreWipeOptions>(configuration.GetSection(PreWipeOptions.Section));
        services.Configure<MessagingOptions>(configuration.GetSection(MessagingOptions.Section));
        services.Configure<ObservabilityOptions>(configuration.GetSection(ObservabilityOptions.Section));
    }
}
