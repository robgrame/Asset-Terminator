using AssetTerminator.Contracts;
using AssetTerminator.Core.Domain;
using Microsoft.Graph;
using Microsoft.Graph.DeviceManagement.ManagedDevices.Item.Wipe;
using Microsoft.Graph.Models;
using Microsoft.Graph.Models.ODataErrors;

namespace AssetTerminator.Providers.Intune;

public sealed class GraphIntuneService
{
    private readonly GraphServiceClient _graph;

    public GraphIntuneService(GraphServiceClient graph)
    {
        _graph = graph;
    }

    public async Task<string?> ResolveManagedDeviceIdAsync(DeviceContext context, CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(context.IntuneManagedDeviceId))
        {
            return context.IntuneManagedDeviceId;
        }

        var device = !string.IsNullOrWhiteSpace(context.DeviceName)
            ? await FindManagedDeviceAsync($"deviceName eq '{EscapeODataString(context.DeviceName)}'", ct).ConfigureAwait(false)
            : null;

        device ??= !string.IsNullOrWhiteSpace(context.SerialNumber)
            ? await FindManagedDeviceAsync($"serialNumber eq '{EscapeODataString(context.SerialNumber)}'", ct).ConfigureAwait(false)
            : null;

        return device?.Id;
    }

    public async Task<ManagedDevice?> GetManagedDeviceAsync(string id, CancellationToken ct)
    {
        try
        {
            return await _graph.DeviceManagement.ManagedDevices[id]
                .GetAsync(cancellationToken: ct)
                .ConfigureAwait(false);
        }
        catch (ODataError ex) when (IsNotFound(ex))
        {
            return null;
        }
        catch (ODataError ex)
        {
            throw GraphIntuneServiceException.From(ex);
        }
        catch (Exception ex) when (IsTransientTransport(ex))
        {
            throw GraphIntuneServiceException.TransientFailure(ex);
        }
    }

    public async Task DeleteManagedDeviceAsync(string id, CancellationToken ct)
    {
        try
        {
            await _graph.DeviceManagement.ManagedDevices[id]
                .DeleteAsync(cancellationToken: ct)
                .ConfigureAwait(false);
        }
        catch (ODataError ex)
        {
            throw GraphIntuneServiceException.From(ex);
        }
        catch (Exception ex) when (IsTransientTransport(ex))
        {
            throw GraphIntuneServiceException.TransientFailure(ex);
        }
    }

    /// <summary>
    /// Issues an Intune retire: removes company data and management state while keeping the
    /// device usable (re-purpose). Asynchronous; success here only means the command was accepted.
    /// </summary>
    public async Task RetireAsync(string id, CancellationToken ct)
    {
        try
        {
            await _graph.DeviceManagement.ManagedDevices[id]
                .Retire
                .PostAsync(cancellationToken: ct)
                .ConfigureAwait(false);
        }
        catch (ODataError ex)
        {
            throw GraphIntuneServiceException.From(ex);
        }
        catch (Exception ex) when (IsTransientTransport(ex))
        {
            throw GraphIntuneServiceException.TransientFailure(ex);
        }
    }

    /// <summary>
    /// Resolves the Windows Autopilot device identity id for the device, matched by serial number.
    /// </summary>
    public async Task<string?> ResolveAutopilotIdentityIdAsync(DeviceContext context, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(context.SerialNumber))
        {
            return null;
        }

        try
        {
            var response = await _graph.DeviceManagement.WindowsAutopilotDeviceIdentities
                .GetAsync(requestConfiguration =>
                {
                    requestConfiguration.QueryParameters.Filter =
                        $"contains(serialNumber,'{EscapeODataString(context.SerialNumber)}')";
                    requestConfiguration.QueryParameters.Top = 1;
                }, ct)
                .ConfigureAwait(false);

            return response?.Value?.FirstOrDefault()?.Id;
        }
        catch (ODataError ex) when (IsNotFound(ex))
        {
            return null;
        }
        catch (ODataError ex)
        {
            throw GraphIntuneServiceException.From(ex);
        }
        catch (Exception ex) when (IsTransientTransport(ex))
        {
            throw GraphIntuneServiceException.TransientFailure(ex);
        }
    }

    /// <summary>Deletes the Windows Autopilot device identity registration.</summary>
    public async Task DeleteAutopilotIdentityAsync(string id, CancellationToken ct)
    {
        try
        {
            await _graph.DeviceManagement.WindowsAutopilotDeviceIdentities[id]
                .DeleteAsync(cancellationToken: ct)
                .ConfigureAwait(false);
        }
        catch (ODataError ex)
        {
            throw GraphIntuneServiceException.From(ex);
        }
        catch (Exception ex) when (IsTransientTransport(ex))
        {
            throw GraphIntuneServiceException.TransientFailure(ex);
        }
    }

    /// <summary>
    /// TODO: Confirm tenant-specific Intune wipe flags with the customer before production use.
    /// </summary>
    public async Task WipeAsync(string id, DeviceType deviceType, CancellationToken ct)
    {
        try
        {
            var body = CreateWipeBody(deviceType);
            await _graph.DeviceManagement.ManagedDevices[id]
                .Wipe
                .PostAsync(body, cancellationToken: ct)
                .ConfigureAwait(false);
        }
        catch (ODataError ex)
        {
            throw GraphIntuneServiceException.From(ex);
        }
        catch (Exception ex) when (IsTransientTransport(ex))
        {
            throw GraphIntuneServiceException.TransientFailure(ex);
        }
    }

    private async Task<ManagedDevice?> FindManagedDeviceAsync(string filter, CancellationToken ct)
    {
        try
        {
            var response = await _graph.DeviceManagement.ManagedDevices
                .GetAsync(requestConfiguration =>
                {
                    requestConfiguration.QueryParameters.Filter = filter;
                    requestConfiguration.QueryParameters.Top = 1;
                }, ct)
                .ConfigureAwait(false);

            return response?.Value?.FirstOrDefault();
        }
        catch (ODataError ex) when (IsNotFound(ex))
        {
            return null;
        }
        catch (ODataError ex)
        {
            throw GraphIntuneServiceException.From(ex);
        }
        catch (Exception ex) when (IsTransientTransport(ex))
        {
            throw GraphIntuneServiceException.TransientFailure(ex);
        }
    }

    private static WipePostRequestBody CreateWipeBody(DeviceType deviceType)
    {
        var body = new WipePostRequestBody
        {
            KeepEnrollmentData = false,
            KeepUserData = false
        };

        // TODO: Confirm customer policy for mobile eSIM retention and macOS unlock-code handling.
        if (deviceType is DeviceType.iOS or DeviceType.Android)
        {
            body.PersistEsimDataPlan = false;
        }

        return body;
    }

    private static string EscapeODataString(string value) => value.Replace("'", "''", StringComparison.Ordinal);

    private static bool IsNotFound(ODataError ex) => ex.ResponseStatusCode == 404;

    private static bool IsTransientTransport(Exception ex) =>
        ex is HttpRequestException or TimeoutException or TaskCanceledException;
}

public sealed class GraphIntuneServiceException : Exception
{
    private GraphIntuneServiceException(string message, bool notFound, bool transient, Exception? innerException = null)
        : base(message, innerException)
    {
        NotFound = notFound;
        Transient = transient;
    }

    public bool NotFound { get; }

    public bool Transient { get; }

    public static GraphIntuneServiceException From(ODataError ex)
    {
        var statusCode = ex.ResponseStatusCode;
        var message = ex.Error?.Message ?? ex.Message;
        return new GraphIntuneServiceException(message, statusCode == 404, statusCode == 429 || statusCode >= 500, ex);
    }

    public static GraphIntuneServiceException TransientFailure(Exception ex) =>
        new(ex.Message, notFound: false, transient: true, ex);
}
