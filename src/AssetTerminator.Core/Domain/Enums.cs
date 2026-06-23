namespace AssetTerminator.Core.Domain;

/// <summary>
/// Lifecycle state of an entire decommission request (the orchestrator's state machine).
/// </summary>
public enum RequestState
{
    Requested,
    Validated,
    GuardrailsFailed, // BLOCKED — no wipe performed
    InProgress,
    PartiallyCompleted,
    Completed,
    Failed,
    TimedOut
}

/// <summary>
/// Independent status of a single sub-action (AD, SCCM, Intune delete, Entra ID, Wipe).
/// </summary>
public enum ActionStatus
{
    Pending,
    InProgress,
    Success,
    Skipped,
    Failed,
    Blocked,
    TimedOut
}

/// <summary>
/// SLA compliance state derived from elapsed time vs the category's max completion time.
/// </summary>
public enum SlaState
{
    WithinSla,
    AtRisk,
    Breached
}

/// <summary>
/// Severity of a guardrail evaluation result.
/// </summary>
public enum GuardrailSeverity
{
    Info,
    Warning,
    Blocking
}
