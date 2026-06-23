using System.Security.Claims;
using Microsoft.AspNetCore.Http;

namespace AssetTerminator.Api.Auth;

/// <summary>
/// Application RBAC roles. Mapped from Entra ID app roles / groups surfaced as claims.
/// </summary>
public static class AppRoles
{
    public const string Operator = "Operator"; // can create requests
    public const string Auditor = "Auditor";   // read-only
    public const string Admin = "Admin";       // manage configuration
    public const string Approver = "Approver"; // can approve guardrail overrides
}

/// <summary>
/// Extracts the caller identity (UPN + roles) from the authenticated principal.
/// In Azure the principal is populated by App Service Authentication (Easy Auth);
/// for local/dev a fallback header (x-debug-roles / x-debug-upn) can be used.
/// </summary>
public static class CallerContext
{
    public static string GetUpn(HttpContext http)
    {
        var user = http.User;
        var upn = user?.FindFirst(ClaimTypes.Upn)?.Value
                  ?? user?.FindFirst("preferred_username")?.Value
                  ?? user?.FindFirst(ClaimTypes.Name)?.Value;
        if (!string.IsNullOrEmpty(upn))
            return upn;
        return http.Request.Headers.TryGetValue("x-debug-upn", out var h) ? h.ToString() : "unknown";
    }

    public static IReadOnlySet<string> GetRoles(HttpContext http)
    {
        var roles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var user = http.User;
        if (user is not null)
        {
            foreach (var c in user.FindAll(ClaimTypes.Role))
                roles.Add(c.Value);
            foreach (var c in user.FindAll("roles"))
                roles.Add(c.Value);
        }
        // Dev fallback (only honored when no authenticated roles are present).
        if (roles.Count == 0 && http.Request.Headers.TryGetValue("x-debug-roles", out var dbg))
            foreach (var r in dbg.ToString().Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                roles.Add(r);
        return roles;
    }

    public static bool IsInRole(HttpContext http, string role) => GetRoles(http).Contains(role);
}
