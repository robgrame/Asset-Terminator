using Azure.Core;
using Azure.Identity;
using Microsoft.Graph;

namespace AssetTerminator.Infrastructure.Graph;

/// <summary>
/// Builds <see cref="GraphServiceClient"/> instances bound to a specific user-assigned
/// managed identity. Per privilege-isolation, each privileged capability host supplies
/// its own UAMI client id; Graph consent is granted on that identity, never in code.
/// </summary>
public static class GraphClientFactory
{
    private static readonly string[] DefaultScopes = ["https://graph.microsoft.com/.default"];

    /// <summary>
    /// Create a Graph client. When <paramref name="managedIdentityClientId"/> is provided,
    /// authentication uses that user-assigned managed identity; otherwise the ambient
    /// credential chain is used (useful for local dev).
    /// </summary>
    public static GraphServiceClient Create(string? managedIdentityClientId)
    {
        TokenCredential credential = string.IsNullOrWhiteSpace(managedIdentityClientId)
            ? new DefaultAzureCredential()
            : new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(managedIdentityClientId));

        return new GraphServiceClient(credential, DefaultScopes);
    }
}
