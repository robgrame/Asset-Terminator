using AssetTerminator.Infrastructure.DependencyInjection;
using AssetTerminator.OnPremAgent;
using AssetTerminator.Providers.ActiveDirectory;
using AssetTerminator.Providers.ConfigMgr;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = Host.CreateApplicationBuilder(args);

var configuration = builder.Configuration;

// Shared infrastructure: state store + immutable audit + Service Bus client + options.
builder.Services.AddAssetTerminatorInfrastructure(configuration);

// On-prem capability providers (run inside the customer network).
builder.Services.AddActiveDirectoryProvider(configuration);
builder.Services.AddConfigMgrProvider(configuration);

builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
