using System.DirectoryServices.Protocols;
using System.Net;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Providers.ActiveDirectory;

public sealed class LdapComputerDirectory
{
    private const string TreeDeleteControlOid = "1.2.840.113556.1.4.805";
    private readonly ILogger<LdapComputerDirectory> _logger;
    private readonly ActiveDirectoryOptions _options;

    public LdapComputerDirectory(IOptions<ActiveDirectoryOptions> options, ILogger<LdapComputerDirectory> logger)
    {
        _options = options.Value;
        _logger = logger;
    }

    public Task<string?> FindComputerDnAsync(string? deviceName, CancellationToken ct)
    {
        var hostName = NormalizeComputerName(deviceName);
        if (string.IsNullOrWhiteSpace(hostName))
        {
            return Task.FromResult<string?>(null);
        }

        // System.DirectoryServices.Protocols is synchronous; keep the provider API async by offloading LDAP I/O.
        return Task.Run(() =>
        {
            ct.ThrowIfCancellationRequested();

            try
            {
                using var connection = CreateConnection();
                var searchBase = string.IsNullOrWhiteSpace(_options.ComputersOu)
                    ? _options.BaseDn
                    : _options.ComputersOu!;
                var escapedName = EscapeLdapFilterValue(hostName);
                var escapedSam = EscapeLdapFilterValue(hostName + "$");
                var request = new SearchRequest(
                    searchBase,
                    $"(&(objectClass=computer)(|(cn={escapedName})(sAMAccountName={escapedSam})))",
                    SearchScope.Subtree,
                    "distinguishedName");

                var response = (SearchResponse)connection.SendRequest(request);
                if (response.Entries.Count == 0)
                {
                    return null;
                }

                var dn = response.Entries[0].Attributes["distinguishedName"]?[0];
                return dn?.ToString();
            }
            catch (Exception ex) when (TryWrapDirectoryException(ex, out var wrapped))
            {
                throw wrapped;
            }
        }, ct);
    }

    public Task DeleteComputerAsync(string distinguishedName, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(distinguishedName))
        {
            throw new ArgumentException("A distinguished name is required.", nameof(distinguishedName));
        }

        // System.DirectoryServices.Protocols is synchronous; keep the provider API async by offloading LDAP I/O.
        return Task.Run(() =>
        {
            ct.ThrowIfCancellationRequested();

            try
            {
                using var connection = CreateConnection();
                var request = new DeleteRequest(distinguishedName);

                // TODO(customer): Confirm whether tree-delete is permitted in the target domain; it is needed
                // when computer objects have child objects such as BitLocker recovery information.
                request.Controls.Add(new DirectoryControl(TreeDeleteControlOid, Array.Empty<byte>(), true, true));

                connection.SendRequest(request);
            }
            catch (Exception ex) when (TryWrapDirectoryException(ex, out var wrapped))
            {
                throw wrapped;
            }
        }, ct);
    }

    private LdapConnection CreateConnection()
    {
        var identifier = string.IsNullOrWhiteSpace(_options.LdapServer)
            ? new LdapDirectoryIdentifier((string?)null, _options.Port, false, false)
            : new LdapDirectoryIdentifier(_options.LdapServer, _options.Port, false, false);

        var connection = new LdapConnection(identifier)
        {
            AuthType = AuthType.Negotiate,
            Timeout = TimeSpan.FromSeconds(30)
        };

        connection.SessionOptions.ProtocolVersion = 3;
        connection.SessionOptions.SecureSocketLayer = _options.UseSsl;

        if (!string.IsNullOrWhiteSpace(_options.Username))
        {
            connection.Credential = new NetworkCredential(_options.Username, _options.Password);
        }

        _logger.LogDebug("Created LDAP connection for server {Server}:{Port}", _options.LdapServer ?? "<domain>", _options.Port);
        return connection;
    }

    private static bool TryWrapDirectoryException(Exception ex, out LdapComputerDirectoryException wrapped)
    {
        switch (ex)
        {
            case DirectoryOperationException directoryOperationException:
            {
                var resultCode = directoryOperationException.Response.ResultCode;
                var notFound = resultCode == ResultCode.NoSuchObject;
                var transient = IsTransient(resultCode);
                wrapped = new LdapComputerDirectoryException(
                    $"LDAP operation failed: {resultCode}. {directoryOperationException.Message}",
                    transient,
                    notFound,
                    directoryOperationException);
                return true;
            }

            case LdapException ldapException:
            {
                var transient = IsTransient(ldapException.ErrorCode);
                wrapped = new LdapComputerDirectoryException(
                    $"LDAP operation failed: {ldapException.Message}",
                    transient,
                    false,
                    ldapException);
                return true;
            }

            default:
                wrapped = null!;
                return false;
        }
    }

    private static bool IsTransient(ResultCode resultCode) =>
        resultCode is ResultCode.TimeLimitExceeded
            or ResultCode.Busy
            or ResultCode.Unavailable
            or ResultCode.UnwillingToPerform;

    private static bool IsTransient(int ldapErrorCode) =>
        ldapErrorCode is 81 or 85 or 88 or 91 or 52;

    private static string? NormalizeComputerName(string? deviceName)
    {
        if (string.IsNullOrWhiteSpace(deviceName))
        {
            return null;
        }

        var normalized = deviceName.Trim().TrimEnd('.');
        if (normalized.EndsWith('$'))
        {
            normalized = normalized[..^1];
        }

        var dotIndex = normalized.IndexOf('.');
        return dotIndex > 0 ? normalized[..dotIndex] : normalized;
    }

    private static string EscapeLdapFilterValue(string value) =>
        value
            .Replace("\\", "\\5c", StringComparison.Ordinal)
            .Replace("*", "\\2a", StringComparison.Ordinal)
            .Replace("(", "\\28", StringComparison.Ordinal)
            .Replace(")", "\\29", StringComparison.Ordinal)
            .Replace("\0", "\\00", StringComparison.Ordinal);
}
