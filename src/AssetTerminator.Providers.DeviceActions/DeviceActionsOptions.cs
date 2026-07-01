namespace AssetTerminator.Providers.DeviceActions;

/// <summary>
/// Configuration for the on-device preventive actions executed by the on-prem agent before a wipe:
/// Enterprise license removal (step-down to Windows Pro) and BIOS/UEFI supervisor password removal.
/// </summary>
public sealed class DeviceActionsOptions
{
    public const string Section = "AssetTerminator:Providers:DeviceActions";

    /// <summary>When true, commands are simulated and never executed against the device.</summary>
    public bool DryRun { get; set; } = true;

    /// <summary>Max time to wait for a launched tool/script to complete.</summary>
    public TimeSpan CommandTimeout { get; set; } = TimeSpan.FromMinutes(5);

    /// <summary>Enterprise license removal command (step-down to Windows Pro).</summary>
    public CommandSpec LicenseRemoval { get; set; } = new();

    /// <summary>
    /// BIOS/UEFI supervisor password removal, keyed by OEM manufacturer (e.g. "Dell", "HP", "Lenovo").
    /// The manufacturer is resolved from the device context signal "Manufacturer", falling back to
    /// <see cref="DefaultManufacturer"/>.
    /// </summary>
    public Dictionary<string, CommandSpec> BiosPasswordRemoval { get; set; } =
        new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Manufacturer to assume when the device context does not report one.</summary>
    public string? DefaultManufacturer { get; set; }
}

/// <summary>
/// A single executable command. <see cref="FileName"/> and <see cref="Arguments"/> support the
/// placeholders {serialNumber}, {deviceName} and {primaryUserUpn}, substituted at run time.
/// </summary>
public sealed class CommandSpec
{
    public string? FileName { get; set; }
    public string? Arguments { get; set; }

    /// <summary>Working directory for the process (optional).</summary>
    public string? WorkingDirectory { get; set; }

    /// <summary>True when a non-zero exit code should still be treated as success (tool-specific).</summary>
    public bool IgnoreExitCode { get; set; }

    public bool IsConfigured => !string.IsNullOrWhiteSpace(FileName);
}
