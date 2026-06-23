using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;

namespace AssetTerminator.Api.Services;

/// <summary>Maps domain state to the public REST response contracts.</summary>
public static class ApiMappings
{
    public static DecommissionStatusResponse ToStatus(DecommissionRecord r) => new()
    {
        RequestId = r.RequestId,
        CorrelationId = r.CorrelationId,
        TicketNumber = r.TicketNumber,
        OverallStatus = r.State.ToString(),
        SlaState = r.SlaState.ToString(),
        CreatedAt = r.CreatedAtUtc,
        LastUpdatedAt = r.LastUpdatedAtUtc,
        DueAt = r.DueAtUtc,
        Actions = r.Actions
            .OrderBy(a => a.Target)
            .Select(a => new DecommissionActionStatus
            {
                Target = a.Target,
                Action = a.Action,
                Status = a.Status.ToString(),
                LastChecked = a.LastCheckedUtc,
                RetryCount = a.RetryCount,
                Details = a.Details
            })
            .ToList()
    };

    public static DecommissionHistoryEvent ToHistory(AuditRecord a) => new()
    {
        Timestamp = a.TimestampUtc,
        EventType = a.Action,
        Target = a.TargetEnvironment,
        Outcome = a.Outcome,
        Actor = a.Actor,
        Detail = a.Reason
    };
}
