using AssetTerminator.Core.Domain;
using Microsoft.Graph;
using Microsoft.Graph.Models;
using Microsoft.Graph.Models.ODataErrors;

namespace AssetTerminator.Providers.EntraId;

public sealed class GraphEntraDeviceService
{
    private readonly GraphServiceClient _graph;

    public GraphEntraDeviceService(GraphServiceClient graph)
    {
        _graph = graph;
    }

    public async Task<string?> ResolveDeviceObjectIdAsync(DeviceContext context, CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(context.EntraDeviceId))
        {
            return context.EntraDeviceId;
        }

        if (string.IsNullOrWhiteSpace(context.DeviceName))
        {
            return null;
        }

        var device = await FindDeviceAsync($"displayName eq '{EscapeODataString(context.DeviceName)}'", ct).ConfigureAwait(false);
        return device?.Id;
    }

    public async Task<bool> ExistsAsync(string objectId, CancellationToken ct) =>
        await GetDeviceAsync(objectId, ct).ConfigureAwait(false) is not null;

    /// <summary>
    /// Deletes by Entra directory object id (Graph device id), not the deviceId registration GUID.
    /// </summary>
    public async Task DeleteDeviceAsync(string objectId, CancellationToken ct)
    {
        try
        {
            await _graph.Devices[objectId]
                .DeleteAsync(cancellationToken: ct)
                .ConfigureAwait(false);
        }
        catch (ODataError ex)
        {
            throw GraphEntraDeviceServiceException.From(ex);
        }
        catch (Exception ex) when (IsTransientTransport(ex))
        {
            throw GraphEntraDeviceServiceException.TransientFailure(ex);
        }
    }

    private async Task<Device?> GetDeviceAsync(string objectId, CancellationToken ct)
    {
        try
        {
            return await _graph.Devices[objectId]
                .GetAsync(cancellationToken: ct)
                .ConfigureAwait(false);
        }
        catch (ODataError ex) when (IsNotFound(ex))
        {
            return null;
        }
        catch (ODataError ex)
        {
            throw GraphEntraDeviceServiceException.From(ex);
        }
        catch (Exception ex) when (IsTransientTransport(ex))
        {
            throw GraphEntraDeviceServiceException.TransientFailure(ex);
        }
    }

    private async Task<Device?> FindDeviceAsync(string filter, CancellationToken ct)
    {
        try
        {
            var response = await _graph.Devices
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
            throw GraphEntraDeviceServiceException.From(ex);
        }
        catch (Exception ex) when (IsTransientTransport(ex))
        {
            throw GraphEntraDeviceServiceException.TransientFailure(ex);
        }
    }

    private static string EscapeODataString(string value) => value.Replace("'", "''", StringComparison.Ordinal);

    private static bool IsNotFound(ODataError ex) => ex.ResponseStatusCode == 404;

    private static bool IsTransientTransport(Exception ex) =>
        ex is HttpRequestException or TimeoutException or TaskCanceledException;
}

public sealed class GraphEntraDeviceServiceException : Exception
{
    private GraphEntraDeviceServiceException(string message, bool notFound, bool transient, Exception? innerException = null)
        : base(message, innerException)
    {
        NotFound = notFound;
        Transient = transient;
    }

    public bool NotFound { get; }

    public bool Transient { get; }

    public static GraphEntraDeviceServiceException From(ODataError ex)
    {
        var statusCode = ex.ResponseStatusCode;
        var message = ex.Error?.Message ?? ex.Message;
        return new GraphEntraDeviceServiceException(message, statusCode == 404, statusCode == 429 || statusCode >= 500, ex);
    }

    public static GraphEntraDeviceServiceException TransientFailure(Exception ex) =>
        new(ex.Message, notFound: false, transient: true, ex);
}
