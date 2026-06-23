using AssetTerminator.Contracts;
using AssetTerminator.Core.Domain;

namespace AssetTerminator.Core.Abstractions;

/// <summary>
/// Sends push callbacks to ServiceNow with retry and dead-letter semantics.
/// Callbacks carry a unique eventId so ServiceNow can dedupe.
/// </summary>
public interface ICallbackSender
{
    Task SendAsync(ServiceNowCallback callback, CancellationToken ct);
}

/// <summary>
/// Enqueues a sub-action for execution. Cloud actions (Intune/Entra) go to the
/// cloud queue; on-prem actions (AD/SCCM) go to the on-prem queue consumed by the
/// self-hosted agent.
/// </summary>
public interface IActionDispatcher
{
    Task DispatchAsync(string requestId, DecommissionTarget target, CancellationToken ct);
}

/// <summary>
/// Classifies SLA state and computes deadlines for a request based on its category.
/// </summary>
public interface ISlaCalculator
{
    DateTimeOffset ComputeDueAt(AssetCategory category, DateTimeOffset createdAtUtc);
    SlaState Evaluate(AssetCategory category, DateTimeOffset createdAtUtc, DateTimeOffset nowUtc);
}
