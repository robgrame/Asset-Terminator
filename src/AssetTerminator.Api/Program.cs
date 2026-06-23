using AssetTerminator.Api.Auth;
using AssetTerminator.Api.Services;
using AssetTerminator.Core.Options;
using AssetTerminator.Guardrails;
using AssetTerminator.Infrastructure.DependencyInjection;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

builder.UseMiddleware<ApiKeyAuthMiddleware>();

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

var configuration = builder.Configuration;

builder.Services.AddAssetTerminatorInfrastructure(configuration);
builder.Services.AddGuardrails(configuration);
builder.Services.Configure<OverrideOptions>(configuration.GetSection(OverrideOptions.Section));

builder.Services.AddScoped<IntakeService>();

builder.Build().Run();
