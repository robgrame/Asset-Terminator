using AssetTerminator.Api.Services;
using AssetTerminator.Core.Abstractions;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace AssetTerminator.Api.Functions;

/// <summary>
/// Query endpoints used by ServiceNow polling: current aggregate status and the
/// immutable event timeline for a request.
/// </summary>
public sealed class DecommissionQueryFunction
{
    private readonly IStateStore _store;
    private readonly IAuditWriter _audit;

    public DecommissionQueryFunction(IStateStore store, IAuditWriter audit)
    {
        _store = store;
        _audit = audit;
    }

    [Function("DecommissionStatus")]
    public async Task<IActionResult> GetStatus(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "v1/decommission/{requestId}")] HttpRequest req,
        string requestId,
        CancellationToken ct)
    {
        var record = await _store.GetAsync(requestId, ct);
        if (record is null)
            return new NotFoundObjectResult(new { status = 404, detail = $"Request '{requestId}' not found." });
        return new OkObjectResult(ApiMappings.ToStatus(record));
    }

    [Function("DecommissionHistory")]
    public async Task<IActionResult> GetHistory(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "v1/decommission/{requestId}/history")] HttpRequest req,
        string requestId,
        CancellationToken ct)
    {
        var record = await _store.GetAsync(requestId, ct);
        if (record is null)
            return new NotFoundObjectResult(new { status = 404, detail = $"Request '{requestId}' not found." });

        var timeline = await _audit.ReadTimelineAsync(requestId, ct);
        return new OkObjectResult(timeline.Select(ApiMappings.ToHistory).ToList());
    }
}
