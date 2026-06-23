using AssetTerminator.Core.Guardrails;

namespace AssetTerminator.Core.Abstractions;

/// <summary>
/// A single immutable audit record. Written append-only to WORM storage. Records are
/// hash-chained (<see cref="PreviousHash"/> -> <see cref="Hash"/>) for tamper-evidence.
/// </summary>
public sealed class AuditRecord
{
    public string CorrelationId { get; set; } = string.Empty;
    public string RequestId { get; set; } = string.Empty;
    public string? TicketNumber { get; set; }
    public string? AssetId { get; set; }

    /// <summary>Event type, e.g. RequestReceived, GuardrailEvaluated, DeleteAttempted, WipeIssued, StateChanged, Override, Callback.</summary>
    public string Action { get; set; } = string.Empty;

    /// <summary>Target environment when applicable (ActiveDirectory, ConfigMgr, Intune, EntraId, Wipe).</summary>
    public string? TargetEnvironment { get; set; }

    /// <summary>Who/what initiated the action (system, requestor, approver UPN).</summary>
    public string Actor { get; set; } = "system";

    public DateTimeOffset TimestampUtc { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>Outcome string (Success | Skipped | Failed | Blocked | InProgress | ...).</summary>
    public string? Outcome { get; set; }

    /// <summary>Human-readable reason or error detail.</summary>
    public string? Reason { get; set; }

    /// <summary>Guardrail results captured at evaluation time (when relevant).</summary>
    public IReadOnlyList<GuardrailResult>? GuardrailResults { get; set; }

    /// <summary>Hash of the previous record in the chain (per request).</summary>
    public string? PreviousHash { get; set; }

    /// <summary>SHA-256 hash of this record's canonical content + PreviousHash.</summary>
    public string? Hash { get; set; }
}

/// <summary>
/// Append-only writer to the immutable audit store (Blob WORM by default).
/// Writes must be reliable: callers audit intent BEFORE destructive actions.
/// </summary>
public interface IAuditWriter
{
    /// <summary>Append a record to the immutable store, computing and persisting its hash chain.</summary>
    Task AppendAsync(AuditRecord record, CancellationToken ct);

    /// <summary>Read the full ordered audit timeline for a request (for history endpoint).</summary>
    Task<IReadOnlyList<AuditRecord>> ReadTimelineAsync(string requestId, CancellationToken ct);
}
