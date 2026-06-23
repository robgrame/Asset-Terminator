using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Options;
using AssetTerminator.Guardrails;
using AssetTerminator.Infrastructure.DependencyInjection;
using AssetTerminator.Infrastructure.Graph;
using AssetTerminator.Orchestrator.Enrichment;
using AssetTerminator.Orchestrator.Polling;
using AssetTerminator.Orchestrator.Services;
using AssetTerminator.Providers.EntraId;
using AssetTerminator.Providers.Intune;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

var configuration = builder.Configuration;

// Shared infrastructure: state store, audit, messaging, callbacks, SLA, secrets.
builder.Services.AddAssetTerminatorInfrastructure(configuration);

// Guardrail engine + built-in guardrails (config-driven).
builder.Services.AddGuardrails(configuration);
builder.Services.Configure<OverrideOptions>(configuration.GetSection(OverrideOptions.Section));

// Cloud capability providers (each binds its own least-privilege UAMI).
builder.Services.AddIntuneProviders();
builder.Services.AddEntraIdProviders();

// Graph client for device enrichment (read-only directory/Intune scope UAMI).
builder.Services.AddSingleton(_ =>
    GraphClientFactory.Create(configuration["AssetTerminator:Enrichment:ManagedIdentityClientId"]));
builder.Services.AddSingleton<IDeviceEnricher, GraphDeviceEnricher>();

// Orchestration + reconciliation services.
builder.Services.AddScoped<CallbackPublisher>();
builder.Services.AddScoped<ReconciliationService>();

builder.Build().Run();
