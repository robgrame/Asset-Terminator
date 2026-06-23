using System.Net;
using System.Net.Sockets;
using AssetTerminator.Core.Options;
using Microsoft.AspNetCore.Http;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Middleware;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Api.Auth;

/// <summary>
/// Authenticates inbound ServiceNow calls on HTTP-triggered functions using a shared
/// API key header plus a source-IP allowlist. The API key (resolved from Key Vault and
/// supplied via configuration) defends against unauthorized callers; the IP allowlist
/// restricts the network origin. Combined with the per-request idempotency key, this
/// also mitigates replay.
/// </summary>
public sealed class ApiKeyAuthMiddleware : IFunctionsWorkerMiddleware
{
    private readonly IOptionsMonitor<IngestionOptions> _options;
    private readonly ILogger<ApiKeyAuthMiddleware> _logger;

    public ApiKeyAuthMiddleware(IOptionsMonitor<IngestionOptions> options, ILogger<ApiKeyAuthMiddleware> logger)
    {
        _options = options;
        _logger = logger;
    }

    public async Task Invoke(FunctionContext context, FunctionExecutionDelegate next)
    {
        var httpContext = context.GetHttpContext();
        if (httpContext is null)
        {
            // Not an HTTP-triggered function (e.g. a timer/queue) — no API-key gate.
            await next(context);
            return;
        }

        var cfg = _options.CurrentValue;

        if (!IsIpAllowed(httpContext, cfg))
        {
            _logger.LogWarning("Rejected request from disallowed IP {Ip}", httpContext.Connection.RemoteIpAddress);
            await WriteProblem(httpContext, StatusCodes.Status403Forbidden, "Source IP not allowed.");
            return;
        }

        if (!IsApiKeyValid(httpContext, cfg))
        {
            _logger.LogWarning("Rejected request with missing/invalid API key");
            await WriteProblem(httpContext, StatusCodes.Status401Unauthorized, "Missing or invalid API key.");
            return;
        }

        await next(context);
    }

    private static bool IsApiKeyValid(HttpContext http, IngestionOptions cfg)
    {
        if (cfg.ApiKeys.Count == 0)
            return false; // fail-closed: no keys configured means no access
        if (!http.Request.Headers.TryGetValue(cfg.ApiKeyHeader, out var provided))
            return false;
        var key = provided.ToString();
        return cfg.ApiKeys.Any(k => CryptographicEquals(k, key));
    }

    private bool IsIpAllowed(HttpContext http, IngestionOptions cfg)
    {
        if (cfg.IpAllowlist.Count == 0)
            return true; // allowlist not configured — allow (log a warning at startup elsewhere)
        var remote = http.Connection.RemoteIpAddress;
        if (remote is null)
            return false;
        if (remote.IsIPv4MappedToIPv6)
            remote = remote.MapToIPv4();
        return cfg.IpAllowlist.Any(entry => IpMatches(entry, remote));
    }

    private static bool IpMatches(string entry, IPAddress remote)
    {
        entry = entry.Trim();
        if (entry.Contains('/'))
            return CidrContains(entry, remote);
        return IPAddress.TryParse(entry, out var single) && single.Equals(remote);
    }

    private static bool CidrContains(string cidr, IPAddress address)
    {
        var parts = cidr.Split('/');
        if (parts.Length != 2 || !IPAddress.TryParse(parts[0], out var network) || !int.TryParse(parts[1], out var prefix))
            return false;
        if (network.AddressFamily != address.AddressFamily)
            return false;

        var networkBytes = network.GetAddressBytes();
        var addressBytes = address.GetAddressBytes();
        if (networkBytes.Length != addressBytes.Length)
            return false;

        int fullBytes = prefix / 8;
        int remainingBits = prefix % 8;
        for (var i = 0; i < fullBytes; i++)
            if (networkBytes[i] != addressBytes[i])
                return false;
        if (remainingBits == 0)
            return true;
        int mask = (byte)~(0xFF >> remainingBits);
        return (networkBytes[fullBytes] & mask) == (addressBytes[fullBytes] & mask);
    }

    private static bool CryptographicEquals(string a, string b)
    {
        var ba = System.Text.Encoding.UTF8.GetBytes(a);
        var bb = System.Text.Encoding.UTF8.GetBytes(b);
        return System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(ba, bb);
    }

    private static async Task WriteProblem(HttpContext http, int status, string detail)
    {
        http.Response.StatusCode = status;
        http.Response.ContentType = "application/problem+json";
        await http.Response.WriteAsync($"{{\"status\":{status},\"detail\":\"{detail}\"}}");
    }
}
