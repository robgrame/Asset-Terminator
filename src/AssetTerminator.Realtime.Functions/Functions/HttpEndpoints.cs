using System.IO;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace AssetTerminator.Realtime.Functions;

/// <summary>
/// HTTP surface served directly by the Flex Consumption function (no App Service plan needed):
/// the live board page at <c>/</c> and the SignalR <c>/negotiate</c> endpoint used by the browser
/// client to obtain a direct, token-authenticated URL to the Azure SignalR Service (serverless).
/// </summary>
public class HttpEndpoints
{
    [Function("index")]
    public IActionResult Index(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "")] HttpRequest req)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "board.html");
        var html = File.ReadAllText(path);
        return new ContentResult { Content = html, ContentType = "text/html", StatusCode = 200 };
    }

    [Function("negotiate")]
    public IActionResult Negotiate(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", "get", Route = "negotiate")] HttpRequest req,
        [SignalRConnectionInfoInput(HubName = "decommissions")] string connectionInfo)
        => new ContentResult { Content = connectionInfo, ContentType = "application/json", StatusCode = 200 };
}
