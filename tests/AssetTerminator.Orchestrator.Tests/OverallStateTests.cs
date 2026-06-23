using AssetTerminator.Contracts;
using AssetTerminator.Core.Domain;
using AssetTerminator.Orchestrator.Orchestration;

namespace AssetTerminator.Orchestrator.Tests;

/// <summary>
/// Unit tests for the overall-state aggregation that drives the request state machine
/// (Completed / InProgress / PartiallyCompleted / Failed).
/// </summary>
public sealed class OverallStateTests
{
    private static DecommissionRecord Record(params (DecommissionTarget Target, ActionStatus Status)[] actions) =>
        new()
        {
            RequestId = "r1",
            CorrelationId = "c1",
            Actions = actions.Select(a => new SubAction
            {
                RequestId = "r1",
                Target = a.Target,
                Status = a.Status
            }).ToList()
        };

    [Fact]
    public void AllSuccessOrSkipped_IsCompleted()
    {
        var record = Record(
            (DecommissionTarget.EntraId, ActionStatus.Success),
            (DecommissionTarget.Intune, ActionStatus.Skipped));

        Assert.Equal(RequestState.Completed, DecommissionActivities.OverallState(record));
    }

    [Fact]
    public void AnyPendingOrInProgress_IsInProgress()
    {
        var record = Record(
            (DecommissionTarget.EntraId, ActionStatus.Success),
            (DecommissionTarget.Wipe, ActionStatus.InProgress));

        Assert.Equal(RequestState.InProgress, DecommissionActivities.OverallState(record));
    }

    [Fact]
    public void SomeSuccessSomeFailed_IsPartiallyCompleted()
    {
        var record = Record(
            (DecommissionTarget.EntraId, ActionStatus.Success),
            (DecommissionTarget.Intune, ActionStatus.Failed));

        Assert.Equal(RequestState.PartiallyCompleted, DecommissionActivities.OverallState(record));
    }

    [Fact]
    public void AllFailed_IsFailed()
    {
        var record = Record(
            (DecommissionTarget.EntraId, ActionStatus.Failed),
            (DecommissionTarget.Intune, ActionStatus.Failed));

        Assert.Equal(RequestState.Failed, DecommissionActivities.OverallState(record));
    }

    [Fact]
    public void BlockedWithSuccess_IsPartiallyCompleted()
    {
        var record = Record(
            (DecommissionTarget.EntraId, ActionStatus.Success),
            (DecommissionTarget.Wipe, ActionStatus.Blocked));

        Assert.Equal(RequestState.PartiallyCompleted, DecommissionActivities.OverallState(record));
    }
}
