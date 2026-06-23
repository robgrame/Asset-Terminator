namespace AssetTerminator.Contracts;

/// <summary>
/// Target management environment for a decommission sub-action.
/// </summary>
public enum DecommissionTarget
{
    ActiveDirectory,
    ConfigMgr,
    Intune,
    EntraId,
    Wipe
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
