namespace AssetTerminator.Contracts;

/// <summary>
/// Target management environment / action for a decommission sub-action.
/// </summary>
public enum DecommissionTarget
{
    ActiveDirectory,
    ConfigMgr,
    Intune,
    EntraId,
    Wipe,

    /// <summary>Delete the device's Windows Autopilot registration (must precede the wipe).</summary>
    Autopilot,

    /// <summary>Pre-wipe: remove the Enterprise (E3/E5) license, stepping the device down to Windows Pro.</summary>
    LicenseRemoval,

    /// <summary>Pre-wipe: clear the BIOS/UEFI supervisor password via the OEM management tool.</summary>
    BiosPasswordRemoval,

    /// <summary>Intune retire: remove company data/management but keep the device usable (re-purpose).</summary>
    Retire
}

/// <summary>
/// Disposition of the asset. Drives whether the device is terminated (wiped) or retired (re-purposed).
/// </summary>
public enum DispositionType
{
    /// <summary>Terminate the device: pre-wipe preventive actions + Autopilot removal + Intune wipe.</summary>
    Terminate,

    /// <summary>Retire the device for re-purpose: Intune retire + object cleanup, no wipe, no Autopilot removal.</summary>
    Retire
}

/// <summary>
/// Device platform. Drives wipe semantics and guardrail selection.
/// </summary>
public enum DeviceType
{
    Windows,
    MacOS,
    iOS,
    Android
}

/// <summary>
/// Business classification of the asset. Drives SLA and approval policy.
/// </summary>
public enum AssetCategory
{
    Standard,
    Vip,
    Critical
}
