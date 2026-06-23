using System.Net;
using System.Text.Json;

namespace AssetTerminator.Providers.ConfigMgr;

public sealed class SccmAdminService
{
    private readonly HttpClient _httpClient;

    public SccmAdminService(HttpClient httpClient)
    {
        _httpClient = httpClient;
    }

    public async Task<long?> FindDeviceResourceIdAsync(string? deviceName, string? serialNumber, CancellationToken ct)
    {
        var normalizedName = NormalizeDeviceName(deviceName);
        if (!string.IsNullOrWhiteSpace(normalizedName))
        {
            var byName = await FindResourceIdByFilterAsync($"Name eq '{EscapeODataString(normalizedName)}'", ct).ConfigureAwait(false);
            if (byName is not null)
            {
                return byName;
            }
        }

        if (!string.IsNullOrWhiteSpace(serialNumber))
        {
            return await FindResourceIdByFilterAsync($"SerialNumber eq '{EscapeODataString(serialNumber.Trim())}'", ct).ConfigureAwait(false);
        }

        return null;
    }

    public async Task DeleteDeviceAsync(long resourceId, CancellationToken ct)
    {
        try
        {
            EnsureConfigured();

            // TODO(customer): Confirm the delete verb/endpoint for the customer's ConfigMgr version.
            // Some AdminService builds use POST wmi/SMS_R_System(<id>)/AdminService.Delete instead.
            using var response = await _httpClient.DeleteAsync($"wmi/SMS_R_System({resourceId})", ct).ConfigureAwait(false);
            ThrowIfUnsuccessful(response, $"delete resourceId {resourceId}");
        }
        catch (Exception ex) when (TryWrapHttpException(ex, ct, out var wrapped))
        {
            throw wrapped;
        }
    }

    private async Task<long?> FindResourceIdByFilterAsync(string filter, CancellationToken ct)
    {
        try
        {
            EnsureConfigured();

            var requestUri = $"wmi/SMS_R_System?$filter={Uri.EscapeDataString(filter)}";
            using var response = await _httpClient.GetAsync(requestUri, ct).ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.NotFound)
            {
                return null;
            }

            ThrowIfUnsuccessful(response, "find device");
            await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: ct).ConfigureAwait(false);

            if (document.RootElement.TryGetProperty("value", out var value) && value.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in value.EnumerateArray())
                {
                    if (TryGetResourceId(item, out var resourceId))
                    {
                        return resourceId;
                    }
                }

            }

            return TryGetResourceId(document.RootElement, out var directResourceId) ? directResourceId : null;
        }
        catch (Exception ex) when (TryWrapHttpException(ex, ct, out var wrapped))
        {
            throw wrapped;
        }
    }

    private void EnsureConfigured()
    {
        if (_httpClient.BaseAddress is null)
        {
            throw new SccmAdminServiceException("ConfigMgr AdminServiceBaseUrl is required.", transient: false, notFound: false);
        }
    }

    private static bool TryGetResourceId(JsonElement element, out long resourceId)
    {
        resourceId = 0;
        if (!element.TryGetProperty("ResourceId", out var id))
        {
            return false;
        }

        return id.ValueKind switch
        {
            JsonValueKind.Number => id.TryGetInt64(out resourceId),
            JsonValueKind.String => long.TryParse(id.GetString(), out resourceId),
            _ => false
        };
    }

    private static void ThrowIfUnsuccessful(HttpResponseMessage response, string operation)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        var status = response.StatusCode;
        var detail = status switch
        {
            HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden =>
                $"ConfigMgr AdminService auth failed ({(int)status} {status}) during {operation}. Check Windows-integrated credentials and AdminService RBAC.",
            HttpStatusCode.NotFound =>
                $"ConfigMgr AdminService resource not found ({(int)status} {status}) during {operation}.",
            _ =>
                $"ConfigMgr AdminService request failed ({(int)status} {status}) during {operation}."
        };

        throw new SccmAdminServiceException(detail, IsTransient(status), status == HttpStatusCode.NotFound);
    }

    private static bool TryWrapHttpException(Exception ex, CancellationToken ct, out SccmAdminServiceException wrapped)
    {
        switch (ex)
        {
            case SccmAdminServiceException sccmAdminServiceException:
                wrapped = sccmAdminServiceException;
                return true;

            case HttpRequestException httpRequestException:
                wrapped = new SccmAdminServiceException(
                    $"ConfigMgr AdminService request failed: {httpRequestException.Message}",
                    httpRequestException.StatusCode is null || IsTransient(httpRequestException.StatusCode.Value),
                    httpRequestException.StatusCode == HttpStatusCode.NotFound,
                    httpRequestException);
                return true;

            case TaskCanceledException taskCanceledException when !ct.IsCancellationRequested:
                wrapped = new SccmAdminServiceException("ConfigMgr AdminService request timed out.", transient: true, notFound: false, taskCanceledException);
                return true;

            default:
                wrapped = null!;
                return false;
        }
    }

    private static bool IsTransient(HttpStatusCode statusCode) =>
        statusCode == HttpStatusCode.RequestTimeout || (int)statusCode >= 500;

    private static string EscapeODataString(string value) =>
        value.Replace("'", "''", StringComparison.Ordinal);

    private static string? NormalizeDeviceName(string? deviceName)
    {
        if (string.IsNullOrWhiteSpace(deviceName))
        {
            return null;
        }

        var normalized = deviceName.Trim().TrimEnd('.');
        var dotIndex = normalized.IndexOf('.');
        return dotIndex > 0 ? normalized[..dotIndex] : normalized;
    }
}
