using System.Text.Json;
using AssetTerminator.Api.Services;
using AssetTerminator.Contracts;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace AssetTerminator.Api.Functions;

/// <summary>
/// HTTP intake: receives ServiceNow decommission requests, validates them, returns
/// 202 Accepted with a correlationId for asynchronous tracking. Idempotent on requestId.
/// </summary>
public sealed class DecommissionIntakeFunction
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private readonly IntakeService _intake;
    private readonly ILogger<DecommissionIntakeFunction> _logger;

    public DecommissionIntakeFunction(IntakeService intake, ILogger<DecommissionIntakeFunction> logger)
    {
        _intake = intake;
        _logger = logger;
    }

    [Function("DecommissionIntake")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "v1/decommission")] HttpRequest req,
        CancellationToken ct)
    {
        string rawJson;
        using (var reader = new StreamReader(req.Body))
            rawJson = await reader.ReadToEndAsync(ct);

        DecommissionRequest? request;
        try
        {
            request = JsonSerializer.Deserialize<DecommissionRequest>(rawJson, Json);
        }
        catch (JsonException ex)
        {
            return new BadRequestObjectResult(new { status = 400, detail = $"Invalid JSON: {ex.Message}" });
        }

        if (request is null)
            return new BadRequestObjectResult(new { status = 400, detail = "Request body is empty." });

        var result = await _intake.SubmitAsync(request, rawJson, ct);
        if (!result.Accepted)
            return new BadRequestObjectResult(new { status = 400, detail = result.Error });

        var body = new DecommissionAccepted
        {
            RequestId = request.RequestId,
            CorrelationId = result.CorrelationId,
            Status = "Accepted",
            StatusUrl = $"/api/v1/decommission/{request.RequestId}"
        };

        // 202 for a freshly accepted request; 202 as well for an idempotent replay (no re-execution).
        return new AcceptedResult(body.StatusUrl, body);
    }
}
