using AssetTerminator.Contracts;
using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;
using Microsoft.Extensions.Logging;

namespace AssetTerminator.Orchestrator.Orchestration;

/// <summary>
/// Durable orchestration for a single decommission request. Executes the controlled
/// sequence: enrich/validate -> independent deletes (cloud inline, on-prem dispatched)
/// -> guardrail-gated wipe -> finalize. Long-running async completion (offline devices,
/// on-prem agent results, wipe completion) is reconciled separately by the polling engine.
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

        // 1. Independent delete actions (everything except the wipe), in parallel.
        var deleteTasks = meta.Targets
            .Where(t => t != DecommissionTarget.Wipe)
            .Select(t => context.CallActivityAsync(nameof(DecommissionActivities.ExecuteDelete), new DeleteInput(requestId, t)))
            .ToList();
        if (deleteTasks.Count > 0)
            await Task.WhenAll(deleteTasks);

        // 2. Guardrail-gated wipe.
        if (meta.WipeRequested)
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

        // 3. Finalize — sets InProgress/Completed/PartiallyCompleted; the poller drives async parts to terminal.
        await context.CallActivityAsync(nameof(DecommissionActivities.Finalize), requestId);
    }
}
