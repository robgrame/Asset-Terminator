using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Providers.DeviceActions;

/// <summary>
/// Pre-wipe preventive action: clears the BIOS/UEFI supervisor password using the OEM management
/// tool (Dell Command | Configure, HP BIOS Configuration Utility, Lenovo, ...). Executed on the
/// device by the on-prem agent. The tool is selected by the device manufacturer.
/// </summary>
public sealed class BiosPasswordRemovalProvider : IDeviceCleanupProvider
{
    private const string ManufacturerSignal = "Manufacturer";

    private readonly ILocalCommandRunner _runner;
    private readonly DeviceActionsOptions _options;
    private readonly ILogger<BiosPasswordRemovalProvider> _logger;

    public BiosPasswordRemovalProvider(
        ILocalCommandRunner runner,
        IOptions<DeviceActionsOptions> options,
        ILogger<BiosPasswordRemovalProvider> logger)
    {
        _runner = runner;
        _options = options.Value;
        _logger = logger;
    }

    public DecommissionTarget Target => DecommissionTarget.BiosPasswordRemoval;

    public Task<bool> ExistsAsync(DeviceContext context, CancellationToken ct) => Task.FromResult(true);

    public async Task<ProviderResult> DeleteAsync(DeviceContext context, CancellationToken ct)
    {
        var manufacturer = ResolveManufacturer(context);
        if (manufacturer is null)
        {
            return ProviderResult.Skipped("device manufacturer unknown; no BIOS tool selected");
        }

        if (!_options.BiosPasswordRemoval.TryGetValue(manufacturer, out var spec) || !spec.IsConfigured)
        {
            return ProviderResult.Skipped($"no BIOS password removal tool configured for '{manufacturer}'");
        }

        if (_options.DryRun)
        {
            return ProviderResult.Success($"[DRY-RUN] would clear BIOS password via '{spec.FileName}' ({manufacturer})");
        }

        try
        {
            var outcome = await _runner.RunAsync(spec, context, _options.CommandTimeout, ct).ConfigureAwait(false);
            if (outcome.TimedOut)
            {
                return ProviderResult.Failed($"BIOS password removal timed out ({manufacturer})", transient: true);
            }

            return outcome.Success
                ? ProviderResult.Success($"BIOS password cleared via {manufacturer} tool (exit {outcome.ExitCode})")
                : ProviderResult.Failed($"BIOS password removal failed (exit {outcome.ExitCode}): {Trim(outcome.Output)}", transient: false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "BIOS password removal failed for {RequestId}", context.RequestId);
            return ProviderResult.Failed(ex.Message, transient: true);
        }
    }

    // On-device one-shot action: completion is recorded when the agent executes it; the poller waits.
    public Task<ProviderResult> GetStatusAsync(DeviceContext context, CancellationToken ct) =>
        Task.FromResult(ProviderResult.Failed("pending on-prem agent execution", transient: true));

    private string? ResolveManufacturer(DeviceContext context)
    {
        if (context.Signals.TryGetValue(ManufacturerSignal, out var value) && !string.IsNullOrWhiteSpace(value))
        {
            return value;
        }

        return string.IsNullOrWhiteSpace(_options.DefaultManufacturer) ? null : _options.DefaultManufacturer;
    }

    private static string Trim(string output) =>
        output.Length > 500 ? output[..500] : output;
}
