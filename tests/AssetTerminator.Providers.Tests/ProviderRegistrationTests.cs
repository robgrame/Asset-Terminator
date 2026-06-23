using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Providers.ActiveDirectory;
using AssetTerminator.Providers.ConfigMgr;
using AssetTerminator.Providers.EntraId;
using AssetTerminator.Providers.Intune;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace AssetTerminator.Providers.Tests;

/// <summary>
/// Verifies each capability provider registers the expected abstractions and capability
/// target, so the orchestrator/agent hosts can resolve them via the common interfaces.
/// </summary>
public sealed class ProviderRegistrationTests
{
    private static IConfiguration EmptyConfig() => new ConfigurationBuilder().Build();

    private static bool Registers<TService, TImpl>(IServiceCollection services) =>
        services.Any(d => d.ServiceType == typeof(TService) && d.ImplementationType == typeof(TImpl));

    [Fact]
    public void AddIntuneProviders_RegistersDeleteAndWipe()
    {
        var services = new ServiceCollection();
        services.AddIntuneProviders();

        Assert.True(Registers<IDeviceCleanupProvider, IntuneDeleteProvider>(services));
        Assert.True(Registers<IWipeProvider, IntuneWipeProvider>(services));
    }

    [Fact]
    public void AddEntraIdProviders_RegistersDelete()
    {
        var services = new ServiceCollection();
        services.AddEntraIdProviders();

        Assert.True(Registers<IDeviceCleanupProvider, EntraIdDeleteProvider>(services));
    }

    [Fact]
    public void AddActiveDirectoryProvider_RegistersCleanup()
    {
        var services = new ServiceCollection();
        services.AddActiveDirectoryProvider(EmptyConfig());

        Assert.True(Registers<IDeviceCleanupProvider, ActiveDirectoryCleanupProvider>(services));
    }

    [Fact]
    public void AddConfigMgrProvider_RegistersCleanup()
    {
        var services = new ServiceCollection();
        services.AddConfigMgrProvider(EmptyConfig());

        Assert.True(Registers<IDeviceCleanupProvider, ConfigMgrCleanupProvider>(services));
    }
}
