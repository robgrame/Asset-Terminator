namespace AssetTerminator.Providers.ConfigMgr;

public sealed class ConfigMgrOptions
{
    public const string Section = "AssetTerminator:Providers:ConfigMgr";

    // AdminService REST root, e.g. https://<smsprovider>/AdminService/.
    public string AdminServiceBaseUrl { get; set; } = "";
    public string? SiteCode { get; set; }
    public bool DryRun { get; set; } = true;

    // TODO(customer): Auth is typically Windows-integrated; confirm the final mode and account model.
    public string AuthMode { get; set; } = "windows";
    public string? Username { get; set; }
    public string? Password { get; set; }
}
