using System.Text.Json;
using Azure.Messaging.EventGrid;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace AssetTerminator.Realtime.Functions;

/// <summary>
/// Bridges the decommission Event Grid custom topic to Azure SignalR: every
/// <c>AssetTerminator.DecommissionStateChanged</c> event is broadcast to all connected
/// clients of the <c>decommissions</c> hub as a <c>stateChanged</c> message. The SignalR
/// connection uses the <c>AzureSignalRConnectionString</c> app setting (identity-based in Azure).
/// </summary>
public class OnDecommissionStateChanged
{
    private readonly ILogger<OnDecommissionStateChanged> _logger;

    public OnDecommissionStateChanged(ILogger<OnDecommissionStateChanged> logger) => _logger = logger;

    [Function("OnDecommissionStateChanged")]
    [SignalROutput(HubName = "decommissions")]
    public SignalRMessageAction Run([EventGridTrigger] EventGridEvent input)
    {
        JsonElement payload;
        try
        {
            payload = input.Data.ToObjectFromJson<JsonElement>();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Unparseable Event Grid payload for subject {Subject}", input.Subject);
            payload = default;
        }

        _logger.LogInformation("Broadcasting state change for {Subject}", input.Subject);

        return new SignalRMessageAction("stateChanged")
        {
            Arguments = [payload]
        };
    }
}
