using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Guardrails;
using AssetTerminator.Core.Options;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Guardrails;

public sealed class GuardrailEngine(
    IEnumerable<IWipeGuardrail> guardrails,
    IOptionsMonitor<GuardrailsOptions> options,
    ILogger<GuardrailEngine> logger) : IGuardrailEngine
{
    public async Task<GuardrailEvaluation> EvaluateAsync(
        DeviceContext context,
        IReadOnlySet<string>? overriddenGuardrailIds,
        CancellationToken ct)
    {
        var results = new List<GuardrailResult>();

        foreach (var guardrail in guardrails)
        {
            ct.ThrowIfCancellationRequested();

            if (!IsEnabled(guardrail.Id))
            {
                logger.LogDebug("Guardrail {GuardrailId} skipped because it is disabled.", guardrail.Id);
                continue;
            }

            var result = await EvaluateGuardrailAsync(guardrail, context, ct).ConfigureAwait(false);

            if (!result.Passed && overriddenGuardrailIds?.Contains(result.GuardrailId) == true)
            {
                result = new GuardrailResult
                {
                    GuardrailId = result.GuardrailId,
                    Passed = true,
                    Severity = GuardrailSeverity.Warning,
                    Reason = $"[OVERRIDDEN] {result.Reason}",
                    Mandatory = result.Mandatory,
                    Overridable = result.Overridable
                };
            }

            logger.LogInformation(
                "Guardrail {GuardrailId} evaluated: Passed={Passed}, Severity={Severity}, Mandatory={Mandatory}, Reason={Reason}",
                result.GuardrailId,
                result.Passed,
                result.Severity,
                result.Mandatory,
                result.Reason);

            results.Add(result);
        }

        return new GuardrailEvaluation { Results = results };
    }

    private bool IsEnabled(string guardrailId) =>
        !options.CurrentValue.Items.TryGetValue(guardrailId, out var guardrailOptions) || guardrailOptions.Enabled;

    private static GuardrailOptions GetOptions(GuardrailsOptions options, string guardrailId) =>
        options.Items.TryGetValue(guardrailId, out var guardrailOptions) ? guardrailOptions : new GuardrailOptions();

    private async Task<GuardrailResult> EvaluateGuardrailAsync(IWipeGuardrail guardrail, DeviceContext context, CancellationToken ct)
    {
        try
        {
            return await guardrail.EvaluateAsync(context, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Guardrail {GuardrailId} threw during evaluation; failing closed.", guardrail.Id);

            var guardrailOptions = GetOptions(options.CurrentValue, guardrail.Id);

            return GuardrailResult.Fail(
                guardrail.Id,
                $"Guardrail '{guardrail.Id}' failed closed after throwing an exception: {ex.Message}",
                GuardrailSeverity.Blocking,
                mandatory: true,
                overridable: guardrailOptions.Overridable);
        }
    }
}
