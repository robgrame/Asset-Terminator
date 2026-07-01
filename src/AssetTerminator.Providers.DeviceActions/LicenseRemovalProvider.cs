using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Providers.DeviceActions;

/// <summary>
/// Pre-wipe preventive action: removes the Enterprise (E3/E5) license so the device steps down to
/// Windows Pro. Executed on the device by the on-prem agent (e.g. changepk/slmgr script).
/// </summary>
public sealed class LicenseRemovalProvider : IDeviceCleanupProvider
{
    private readonly ILocalCommandRunner _runner;
    private readonly DeviceActionsOptions _options;
    private readonly ILogger<LicenseRemovalProvider> _logger;

    public LicenseRemovalProvider(
        ILocalCommandRunner runner,
        IOptions<DeviceActionsOptions> options,
        ILogger<LicenseRemovalProvider> logger)
    {
        _runner = runner;
        _options = options.Value;
        _logger = logger;
    }

    public DecommissionTarget Target => DecommissionTarget.LicenseRemoval;

    public Task<bool> ExistsAsync(DeviceContext context, CancellationToken ct) => Task.FromResult(true);

    public async Task<ProviderResult> DeleteAsync(DeviceContext context, CancellationToken ct)
    {
        var spec = _options.LicenseRemoval;
        if (!spec.IsConfigured)
        {
            return ProviderResult.Skipped("license removal command not configured");
        }

        if (_options.DryRun)
        {
            return ProviderResult.Success($"[DRY-RUN] would remove Enterprise license via '{spec.FileName}'");
        }

        try
        {
            var outcome = await _runner.RunAsync(spec, context, _options.CommandTimeout, ct).ConfigureAwait(false);
            if (outcome.TimedOut)
            {
                return ProviderResult.Failed("license removal timed out", transient: true);
            }

            return outcome.Success
                ? ProviderResult.Success($"Enterprise license removed (exit {outcome.ExitCode})")
                : ProviderResult.Failed($"license removal failed (exit {outcome.ExitCode}): {Trim(outcome.Output)}", transient: false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "License removal failed for {RequestId}", context.RequestId);
            return ProviderResult.Failed(ex.Message, transient: true);
        }
    }

    // On-device one-shot action: completion is recorded when the agent executes it; the poller waits.
    public Task<ProviderResult> GetStatusAsync(DeviceContext context, CancellationToken ct) =>
        Task.FromResult(ProviderResult.Failed("pending on-prem agent execution", transient: true));

    private static string Trim(string output) =>
        output.Length > 500 ? output[..500] : output;
}
