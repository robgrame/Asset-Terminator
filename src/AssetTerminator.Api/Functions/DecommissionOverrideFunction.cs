using System.Text.Json;
using AssetTerminator.Api.Auth;
using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Options;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Api.Functions;

/// <summary>
/// Guardrail override endpoint. Requires the Approver role and a mandatory reason.
/// Records each approval immutably; once the configured number of distinct approvers
/// (e.g. 2 for VIP assets) is reached, the workflow is re-queued so the orchestrator
/// re-evaluates guardrails honoring the override.
/// </summary>
public sealed class DecommissionOverrideFunction
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private readonly IStateStore _store;
    private readonly IAuditWriter _audit;
    private readonly IWorkflowStarter _workflow;
    private readonly IOptionsMonitor<OverrideOptions> _options;
    private readonly ILogger<DecommissionOverrideFunction> _logger;

    public DecommissionOverrideFunction(
        IStateStore store,
        IAuditWriter audit,
        IWorkflowStarter workflow,
        IOptionsMonitor<OverrideOptions> options,
        ILogger<DecommissionOverrideFunction> logger)
    {
        _store = store;
        _audit = audit;
        _workflow = workflow;
        _options = options;
        _logger = logger;
    }

    [Function("DecommissionOverride")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "v1/decommission/{requestId}/override")] HttpRequest req,
        string requestId,
        CancellationToken ct)
    {
        var http = req.HttpContext;
        if (!CallerContext.IsInRole(http, AppRoles.Approver))
            return new ObjectResult(new { status = 403, detail = "Approver role required." }) { StatusCode = StatusCodes.Status403Forbidden };

        OverrideRequest? body;
        try
        {
            body = await JsonSerializer.DeserializeAsync<OverrideRequest>(req.Body, Json, ct);
        }
        catch (JsonException ex)
        {
            return new BadRequestObjectResult(new { status = 400, detail = $"Invalid JSON: {ex.Message}" });
        }

        if (body is null || string.IsNullOrWhiteSpace(body.Reason))
            return new BadRequestObjectResult(new { status = 400, detail = "A non-empty reason is required." });

        var record = await _store.GetAsync(requestId, ct);
        if (record is null)
            return new NotFoundObjectResult(new { status = 404, detail = $"Request '{requestId}' not found." });

        if (record.State != RequestState.GuardrailsFailed)
            return new ConflictObjectResult(new { status = 409, detail = $"Request is not in a blocked state (current: {record.State})." });

        var approver = CallerContext.GetUpn(http);

        var existing = await _store.GetOverridesAsync(requestId, ct);
        if (existing.Any(g => string.Equals(g.ApproverUpn, approver, StringComparison.OrdinalIgnoreCase)))
            return new ConflictObjectResult(new { status = 409, detail = "This approver has already signed off." });

        var grant = new OverrideGrant
        {
            RequestId = requestId,
            ApproverUpn = approver,
            Reason = body.Reason,
            GuardrailIds = body.GuardrailIds ?? new List<string>()
        };
        await _store.AddOverrideAsync(grant, ct);

        await _audit.AppendAsync(new AuditRecord
        {
            CorrelationId = record.CorrelationId,
            RequestId = requestId,
            TicketNumber = record.TicketNumber,
            AssetId = record.AssetId,
            Action = "GuardrailOverride",
            Actor = approver,
            Outcome = "Approved",
            Reason = $"{body.Reason} | guardrails: {string.Join(',', grant.GuardrailIds)}"
        }, ct);

        var approvals = existing.Count + 1;
        var required = _options.CurrentValue.RequiredFor(record.AssetCategory);

        if (approvals >= required)
        {
            _logger.LogInformation("Override quorum reached for {RequestId} ({Approvals}/{Required}); re-queuing workflow", requestId, approvals, required);
            record.State = RequestState.Validated;
            await _store.UpdateAsync(record, ct);
            await _workflow.StartAsync(requestId, record.CorrelationId, ct);
        }

        return new AcceptedResult($"/api/v1/decommission/{requestId}",
            new { requestId, approvals, required, applied = approvals >= required });
    }
}
