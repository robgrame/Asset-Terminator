namespace AssetTerminator.Providers.ActiveDirectory;

public sealed class ActiveDirectoryOptions
{
    public const string Section = "AssetTerminator:Providers:ActiveDirectory";

    public string? LdapServer { get; set; }
    public int Port { get; set; } = 636;
    public bool UseSsl { get; set; } = true;
    public string BaseDn { get; set; } = "";
    public string? ComputersOu { get; set; }

    // TODO(customer): Prefer gMSA / integrated auth. If explicit credentials are required,
    // resolve Username/Password from Key Vault rather than storing secrets in configuration.
    public string? Username { get; set; }
    public string? Password { get; set; }

    public bool DryRun { get; set; } = true;
}
