using AssetTerminator.Contracts;
using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;
using Microsoft.Extensions.Logging;

namespace AssetTerminator.Orchestrator.Orchestration;

/// <summary>
/// Durable orchestration for a single decommission request.
/// <para>
/// <b>Terminate</b>: enrich/validate -> object deletes incl. Autopilot removal (Autopilot always
/// completes before the wipe) -> on-device pre-wipe preventive actions (license step-down + BIOS
/// password removal) dispatched and awaited to completion -> guardrail-gated wipe -> finalize.
/// </para>
/// <para>
/// <b>Retire</b> (re-purpose): enrich/validate -> object deletes + Intune retire -> finalize.
/// No wipe, no Autopilot removal, no preventive actions.
/// </para>
/// Long-running async completion (offline devices, on-prem agent results, wipe/retire completion)
/// is reconciled separately by the polling engine.
/// </summary>
public static class DecommissionOrchestrator
{
    [Function(nameof(DecommissionOrchestrator))]
    public static async Task RunOrchestrator(
        [OrchestrationTrigger] TaskOrchestrationContext context)
    {
        var requestId = context.GetInput<string>()!;
        var logger = context.CreateReplaySafeLogger(nameof(DecommissionOrchestrator));

        var meta = await context.CallActivityAsync<RequestMeta>(nameof(DecommissionActivities.EnrichAndValidate), requestId);
        var targets = meta.Targets;

        if (meta.Disposition == DispositionType.Retire)
        {
            await RunRetireAsync(context, requestId, targets);
            await context.CallActivityAsync(nameof(DecommissionActivities.Finalize), requestId);
            return;
        }

        // --- Terminate ---

        // 1. Object deletes (AD, ConfigMgr, Intune, EntraId) + Autopilot removal, in parallel.
        //    Awaiting these guarantees the Autopilot registration is removed before the wipe.
        var deleteTargets = targets.Where(IsObjectDeleteOrAutopilot).ToList();
        if (deleteTargets.Count > 0)
        {
            await Task.WhenAll(deleteTargets
                .Select(t => context.CallActivityAsync(nameof(DecommissionActivities.ExecuteDelete), new DeleteInput(requestId, t))));
        }

        var wipeRequested = targets.Contains(DecommissionTarget.Wipe);

        // 2. On-device pre-wipe preventive actions (license step-down + BIOS password removal).
        var preWipeTargets = targets.Where(IsPreWipeGating).ToList();
        if (preWipeTargets.Count > 0)
        {
            await Task.WhenAll(preWipeTargets
                .Select(t => context.CallActivityAsync(nameof(DecommissionActivities.ExecuteDelete), new DeleteInput(requestId, t))));

            if (wipeRequested)
            {
                var status = await WaitForPreWipeCompletionAsync(context, requestId, preWipeTargets, meta.PreWipePollInterval);

                if (!status.AllSucceeded && meta.RequirePreWipeCompletion)
                {
                    var reasons = status.FailedReasons.Count > 0
                        ? status.FailedReasons
                        : new List<string> { "pre-wipe preventive actions did not complete before the deadline" };
                    logger.LogWarning("Pre-wipe preventive actions incomplete for {RequestId}; blocking wipe: {Reasons}",
                        requestId, string.Join("; ", reasons));
                    await context.CallActivityAsync(nameof(DecommissionActivities.BlockWipe),
                        new BlockInput(requestId, reasons, "PreWipeBlocked"));
                    return;
                }
            }
        }

        // 3. Guardrail-gated wipe.
        if (wipeRequested)
        {
            var outcome = await context.CallActivityAsync<GuardrailOutcome>(nameof(DecommissionActivities.EvaluateGuardrails), requestId);
            if (outcome.Allowed)
            {
                logger.LogInformation("Guardrails passed for {RequestId}; issuing wipe", requestId);
                await context.CallActivityAsync(nameof(DecommissionActivities.IssueWipe), requestId);
            }
            else
            {
                logger.LogWarning("Guardrails blocked wipe for {RequestId}: {Reasons}", requestId, string.Join("; ", outcome.BlockingReasons));
                await context.CallActivityAsync(nameof(DecommissionActivities.BlockWipe), new BlockInput(requestId, outcome.BlockingReasons));
                return; // blocked: stop here; override flow may re-start this orchestration
            }
        }

        // 4. Finalize.
        await context.CallActivityAsync(nameof(DecommissionActivities.Finalize), requestId);
    }

    private static async Task RunRetireAsync(TaskOrchestrationContext context, string requestId, List<DecommissionTarget> targets)
    {
        var tasks = targets
            .Where(IsObjectDelete)
            .Select(t => context.CallActivityAsync(nameof(DecommissionActivities.ExecuteDelete), new DeleteInput(requestId, t)))
            .ToList();

        if (targets.Contains(DecommissionTarget.Retire))
        {
            tasks.Add(context.CallActivityAsync(nameof(DecommissionActivities.ExecuteRetire), requestId));
        }

        if (tasks.Count > 0)
            await Task.WhenAll(tasks);
    }

    /// <summary>
    /// Polls the store (via an activity) until the on-device preventive actions reach a terminal
    /// state or the request deadline passes, using durable timers between checks.
    /// </summary>
    private static async Task<PreWipeStatus> WaitForPreWipeCompletionAsync(
        TaskOrchestrationContext context, string requestId, List<DecommissionTarget> targets, TimeSpan pollInterval)
    {
        var interval = pollInterval <= TimeSpan.Zero ? TimeSpan.FromMinutes(5) : pollInterval;

        while (true)
        {
            var status = await context.CallActivityAsync<PreWipeStatus>(
                nameof(DecommissionActivities.CheckPreWipeActions), new CheckPreWipeInput(requestId, targets));

            if (status.AllTerminal || status.DeadlinePassed)
            {
                return status;
            }

            await context.CreateTimer(context.CurrentUtcDateTime.Add(interval), CancellationToken.None);
        }
    }

    private static bool IsObjectDelete(DecommissionTarget t) =>
        t is DecommissionTarget.ActiveDirectory
            or DecommissionTarget.ConfigMgr
            or DecommissionTarget.Intune
            or DecommissionTarget.EntraId;

    private static bool IsObjectDeleteOrAutopilot(DecommissionTarget t) =>
        IsObjectDelete(t) || t == DecommissionTarget.Autopilot;

    private static bool IsPreWipeGating(DecommissionTarget t) =>
        t is DecommissionTarget.LicenseRemoval or DecommissionTarget.BiosPasswordRemoval;
}
