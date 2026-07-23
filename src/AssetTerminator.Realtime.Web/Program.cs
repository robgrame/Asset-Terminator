using Azure.Identity;
using Microsoft.Azure.SignalR;
using Microsoft.Azure.SignalR.Management;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();

const string HubName = "decommissions";

// Build the SignalR ServiceManager once. Prefer a connection string (local dev / classic),
// otherwise fall back to identity-based access using the service endpoint + DefaultAzureCredential.
var connectionString = builder.Configuration["Azure:SignalR:ConnectionString"]
    ?? builder.Configuration.GetConnectionString("AzureSignalR");
var endpoint = builder.Configuration["Azure:SignalR:Endpoint"];

builder.Services.AddSingleton<ServiceManager>(_ =>
{
    var b = new ServiceManagerBuilder().WithOptions(o =>
    {
        if (!string.IsNullOrWhiteSpace(connectionString))
        {
            o.ConnectionString = connectionString;
        }
        else if (!string.IsNullOrWhiteSpace(endpoint))
        {
            o.ServiceEndpoints = [new ServiceEndpoint(new Uri(endpoint), new DefaultAzureCredential())];
        }

        o.ServiceTransportType = ServiceTransportType.Transient;
    });
    return b.BuildServiceManager();
});

var app = builder.Build();

app.UseStaticFiles();
app.MapRazorPages();

// SignalR negotiate endpoint: returns the client the URL + access token to connect directly
// to the Azure SignalR Service (serverless mode). Same-origin, so no CORS needed.
app.MapPost("/negotiate", async (ServiceManager serviceManager, CancellationToken ct) =>
{
    var hubContext = await serviceManager.CreateHubContextAsync(HubName, ct);
    var negotiate = await hubContext.NegotiateAsync(cancellationToken: ct);
    return Results.Json(new { url = negotiate.Url, accessToken = negotiate.AccessToken });
});

app.Run();
