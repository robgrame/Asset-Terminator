using AssetTerminator.Contracts;
using AssetTerminator.Core.Domain;

namespace AssetTerminator.Core.Abstractions;

/// <summary>
/// Transactional current-state store (Azure SQL serverless by default). Holds the
/// real-time, queryable state — never used for the immutable audit.
/// </summary>
public interface IStateStore
{
    /// <summary>
    /// Idempotent create: if a record with the same requestId already exists, returns it
    /// and <paramref name="created"/> = false; otherwise persists and returns the new record.
    /// </summary>
    Task<(DecommissionRecord Record, bool Created)> GetOrCreateAsync(
        DecommissionRecord record, CancellationToken ct);

    Task<DecommissionRecord?> GetAsync(string requestId, CancellationToken ct);

    Task UpdateAsync(DecommissionRecord record, CancellationToken ct);

    /// <summary>Return requests that are still active (not in a terminal state) for the polling engine.</summary>
    Task<IReadOnlyList<DecommissionRecord>> GetActiveAsync(int max, CancellationToken ct);

    /// <summary>Persist an approved override for a request (who/when/which guardrails/why).</summary>
    Task AddOverrideAsync(OverrideGrant grant, CancellationToken ct);

    /// <summary>Get all override grants recorded for a request.</summary>
    Task<IReadOnlyList<OverrideGrant>> GetOverridesAsync(string requestId, CancellationToken ct);
}

/// <summary>
/// A persisted, approved guardrail override.
/// </summary>
public sealed class OverrideGrant
{
    public long Id { get; set; }
    public required string RequestId { get; set; }
    public required string ApproverUpn { get; set; }
    public required string Reason { get; set; }
    public List<string> GuardrailIds { get; set; } = new();
    public DateTimeOffset ApprovedAtUtc { get; set; } = DateTimeOffset.UtcNow;
}
