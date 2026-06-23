using Azure.Security.KeyVault.Secrets;

namespace AssetTerminator.Infrastructure.Secrets;

/// <summary>
/// Resolves secret values by reference (e.g. a Key Vault secret name). Keeps callers
/// free of any plaintext secret handling.
/// </summary>
public interface ISecretResolver
{
    Task<string?> ResolveAsync(string? secretRef, CancellationToken ct);
}

/// <summary>
/// Key Vault-backed secret resolver. A null/empty reference resolves to null.
/// </summary>
public sealed class KeyVaultSecretResolver : ISecretResolver
{
    private readonly SecretClient _client;

    public KeyVaultSecretResolver(SecretClient client) => _client = client;

    public async Task<string?> ResolveAsync(string? secretRef, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(secretRef))
            return null;
        var secret = await _client.GetSecretAsync(secretRef, cancellationToken: ct);
        return secret.Value.Value;
    }
}
