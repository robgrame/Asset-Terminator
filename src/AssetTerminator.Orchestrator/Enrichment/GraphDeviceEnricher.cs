using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using Microsoft.Extensions.Logging;
using Microsoft.Graph;

namespace AssetTerminator.Orchestrator.Enrichment;

/// <summary>
/// Microsoft Graph-backed device enricher. Resolves the Intune managed device and the
/// Entra device object, and reads encryption state, last activity and the primary
/// user's account status so guardrails can evaluate a faithful device picture.
/// </summary>
public sealed class GraphDeviceEnricher : IDeviceEnricher
{
    private readonly GraphServiceClient _graph;
    private readonly ILogger<GraphDeviceEnricher> _logger;

    public GraphDeviceEnricher(GraphServiceClient graph, ILogger<GraphDeviceEnricher> logger)
    {
        _graph = graph;
        _logger = logger;
    }

    public async Task EnrichAsync(DeviceContext context, CancellationToken ct)
    {
        await EnrichFromIntuneAsync(context, ct);
        await EnrichFromEntraAsync(context, ct);
        await EnrichPrimaryUserAsync(context, ct);
    }

    private async Task EnrichFromIntuneAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            var filter = BuildDeviceFilter(context);
            if (filter is null)
                return;

            var page = await _graph.DeviceManagement.ManagedDevices.GetAsync(r =>
            {
                r.QueryParameters.Filter = filter;
                r.QueryParameters.Top = 1;
            }, ct);

            var device = page?.Value?.FirstOrDefault();
            if (device is null)
                return;

            context.IntuneManagedDeviceId = device.Id;
            context.LastActivityUtc = device.LastSyncDateTime ?? context.LastActivityUtc;

            // isEncrypted reflects BitLocker (Windows) / FileVault (macOS) state in Intune.
            if (device.IsEncrypted.HasValue)
                context.IsEncrypted = device.IsEncrypted;

            context.Signals["intune.complianceState"] = device.ComplianceState?.ToString();
            context.Signals["intune.managementState"] = device.ManagementState?.ToString();

            // TODO(customer): for BitLocker recovery-key escrow use the
            // /informationProtection/bitlocker/recoveryKeys API filtered by deviceId
            // (requires BitlockerKey.Read.All). Left as a signal for a custom guardrail.
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Intune enrichment failed for {Device}", context.DeviceName);
        }
    }

    private async Task EnrichFromEntraAsync(DeviceContext context, CancellationToken ct)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(context.DeviceName))
                return;

            var page = await _graph.Devices.GetAsync(r =>
            {
                r.QueryParameters.Filter = $"displayName eq '{Escape(context.DeviceName)}'";
                r.QueryParameters.Top = 1;
            }, ct);

            var device = page?.Value?.FirstOrDefault();
            if (device is null)
                return;

            context.EntraDeviceId = device.Id; // directory object id used for delete
            if (device.ApproximateLastSignInDateTime is { } lastSignIn &&
                (context.LastActivityUtc is null || lastSignIn > context.LastActivityUtc))
            {
                context.LastActivityUtc = lastSignIn;
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Entra enrichment failed for {Device}", context.DeviceName);
        }
    }

    private async Task EnrichPrimaryUserAsync(DeviceContext context, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(context.PrimaryUserUpn))
            return;
        try
        {
            var user = await _graph.Users[context.PrimaryUserUpn].GetAsync(r =>
            {
                r.QueryParameters.Select = ["accountEnabled"];
            }, ct);
            context.PrimaryUserDisabled = user?.AccountEnabled is false;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Primary-user enrichment failed for {Upn}", context.PrimaryUserUpn);
        }
    }

    private static string? BuildDeviceFilter(DeviceContext context)
    {
        if (!string.IsNullOrWhiteSpace(context.DeviceName))
            return $"deviceName eq '{Escape(context.DeviceName)}'";
        if (!string.IsNullOrWhiteSpace(context.SerialNumber))
            return $"serialNumber eq '{Escape(context.SerialNumber)}'";
        return null;
    }

    private static string Escape(string value) => value.Replace("'", "''");
}
