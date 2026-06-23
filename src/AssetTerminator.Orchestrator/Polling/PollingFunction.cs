using AssetTerminator.Orchestrator.Polling;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace AssetTerminator.Orchestrator.Polling;

/// <summary>
/// Timer-triggered reconciliation engine. Periodically re-checks every active
/// decommission request: verifies real provider/wipe state, applies retry-with-backoff,
/// enforces SLA and the give-up timeout, and pushes ServiceNow callbacks. The schedule
/// is configurable via the <c>AssetTerminator:Orchestration:PollingCron</c> app setting.
/// </summary>
public sealed class PollingFunction
{
    private const int BatchSize = 200;

    private readonly ReconciliationService _reconciler;
    private readonly ILogger<PollingFunction> _logger;

    public PollingFunction(ReconciliationService reconciler, ILogger<PollingFunction> logger)
    {
        _reconciler = reconciler;
        _logger = logger;
    }

    [Function(nameof(PollingFunction))]
    public async Task Run(
        [TimerTrigger("%AssetTerminator:Orchestration:PollingCron%")] TimerInfo timer,
        CancellationToken ct)
    {
        _logger.LogInformation("Reconciliation tick (past due: {Past})", timer.IsPastDue);
        try
        {
            await _reconciler.ReconcileAllAsync(BatchSize, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Reconciliation tick failed");
            throw;
        }
    }
}
