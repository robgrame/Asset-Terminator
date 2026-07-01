using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Options;
using AssetTerminator.Orchestrator.Polling;
using AssetTerminator.Orchestrator.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Moq;

namespace AssetTerminator.Orchestrator.Tests;

/// <summary>
/// Unit tests for the polling/reconciliation engine: timeout/give-up, transient
/// retry-with-backoff, permanent failure after max retries, and async wipe completion.
/// </summary>
public sealed class ReconciliationServiceTests
{
    private sealed class TestMonitor<T>(T value) : IOptionsMonitor<T>
    {
        public T CurrentValue { get; } = value;
        public T Get(string? name) => CurrentValue;
        public IDisposable? OnChange(Action<T, string?> listener) => null;
    }

    private readonly Mock<IStateStore> _store = new();
    private readonly Mock<IAuditWriter> _audit = new();
    private readonly Mock<IWipeProvider> _wipe = new();
    private readonly Mock<IRetireProvider> _retire = new();
    private readonly Mock<ISlaCalculator> _sla = new();
    private readonly Mock<IOperationalTelemetry> _telemetry = new();
    private readonly Mock<ICallbackSender> _callbackSender = new();

    private ReconciliationService CreateService(IEnumerable<IDeviceCleanupProvider> providers)
    {
        _sla.Setup(s => s.Evaluate(It.IsAny<AssetCategory>(), It.IsAny<DateTimeOffset>(), It.IsAny<DateTimeOffset>()))
            .Returns(SlaState.WithinSla);

        var publisher = new CallbackPublisher(_callbackSender.Object, _audit.Object, _telemetry.Object, NullLogger<CallbackPublisher>.Instance);

        return new ReconciliationService(
            _store.Object,
            _audit.Object,
            _wipe.Object,
            _retire.Object,
            providers,
            _sla.Object,
            publisher,
            _telemetry.Object,
            new TestMonitor<OrchestrationOptions>(new OrchestrationOptions()),
            new TestMonitor<SlaOptions>(new SlaOptions()),
            NullLogger<ReconciliationService>.Instance);
    }

    private static DecommissionRecord Record(SubAction action, DateTimeOffset dueAt) => new()
    {
        RequestId = "r1",
        CorrelationId = "c1",
        AssetId = "asset-1",
        DeviceName = "PC-1",
        AssetCategory = AssetCategory.Standard,
        State = RequestState.InProgress,
        CreatedAtUtc = DateTimeOffset.UtcNow.AddHours(-1),
        DueAtUtc = dueAt,
        Actions = [action]
    };

    [Fact]
    public async Task PastDue_TimesOutRequestAndActions()
    {
        var action = new SubAction { RequestId = "r1", Target = DecommissionTarget.Wipe, Status = ActionStatus.InProgress };
        var record = Record(action, DateTimeOffset.UtcNow.AddMinutes(-1));

        await CreateService([]).ReconcileAsync(record, CancellationToken.None);

        Assert.Equal(RequestState.TimedOut, record.State);
        Assert.Equal(ActionStatus.TimedOut, action.Status);
        _callbackSender.Verify(c => c.SendAsync(It.Is<ServiceNowCallback>(cb => cb.OverallStatus == "TimedOut"), It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task WipeCompleted_MarksActionSuccess()
    {
        var action = new SubAction { RequestId = "r1", Target = DecommissionTarget.Wipe, Status = ActionStatus.InProgress };
        var record = Record(action, DateTimeOffset.UtcNow.AddDays(1));
        _wipe.Setup(w => w.GetWipeStatusAsync(It.IsAny<DeviceContext>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(ProviderResult.Success("device gone"));

        await CreateService([]).ReconcileAsync(record, CancellationToken.None);

        Assert.Equal(ActionStatus.Success, action.Status);
        Assert.Equal("Success", action.FinalOutcome);
        Assert.Equal(RequestState.Completed, record.State);
    }

    [Fact]
    public async Task TransientFailure_RetriesWithBackoff()
    {
        var action = new SubAction { RequestId = "r1", Target = DecommissionTarget.EntraId, Status = ActionStatus.InProgress };
        var record = Record(action, DateTimeOffset.UtcNow.AddDays(1));
        var provider = ProviderFor(DecommissionTarget.EntraId, ProviderResult.Failed("still present", transient: true));

        await CreateService([provider]).ReconcileAsync(record, CancellationToken.None);

        Assert.Equal(ActionStatus.InProgress, action.Status);
        Assert.Equal(1, action.RetryCount);
        Assert.NotNull(action.NextAttemptUtc);
        Assert.True(action.NextAttemptUtc > DateTimeOffset.UtcNow);
    }

    [Fact]
    public async Task MaxRetriesExceeded_MarksFailed()
    {
        var action = new SubAction { RequestId = "r1", Target = DecommissionTarget.EntraId, Status = ActionStatus.InProgress, RetryCount = 9 };
        var record = Record(action, DateTimeOffset.UtcNow.AddDays(1));
        var provider = ProviderFor(DecommissionTarget.EntraId, ProviderResult.Failed("still present", transient: true));

        await CreateService([provider]).ReconcileAsync(record, CancellationToken.None);

        Assert.Equal(ActionStatus.Failed, action.Status);
        Assert.Equal("Failed", action.FinalOutcome);
    }

    [Fact]
    public async Task PermanentFailure_MarksFailedImmediately()
    {
        var action = new SubAction { RequestId = "r1", Target = DecommissionTarget.EntraId, Status = ActionStatus.InProgress };
        var record = Record(action, DateTimeOffset.UtcNow.AddDays(1));
        var provider = ProviderFor(DecommissionTarget.EntraId, ProviderResult.Failed("forbidden", transient: false));

        await CreateService([provider]).ReconcileAsync(record, CancellationToken.None);

        Assert.Equal(ActionStatus.Failed, action.Status);
        Assert.Equal("Failed", action.FinalOutcome);
    }

    [Fact]
    public async Task RetireCompleted_MarksActionSuccess()
    {
        var action = new SubAction { RequestId = "r1", Target = DecommissionTarget.Retire, Status = ActionStatus.InProgress };
        var record = Record(action, DateTimeOffset.UtcNow.AddDays(1));
        record.DispositionType = DispositionType.Retire;
        _retire.Setup(r => r.GetRetireStatusAsync(It.IsAny<DeviceContext>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(ProviderResult.Success("retired"));

        await CreateService([]).ReconcileAsync(record, CancellationToken.None);

        Assert.Equal(ActionStatus.Success, action.Status);
        Assert.Equal("Success", action.FinalOutcome);
    }

    private static IDeviceCleanupProvider ProviderFor(DecommissionTarget target, ProviderResult status)
    {
        var mock = new Mock<IDeviceCleanupProvider>();
        mock.SetupGet(p => p.Target).Returns(target);
        mock.Setup(p => p.GetStatusAsync(It.IsAny<DeviceContext>(), It.IsAny<CancellationToken>())).ReturnsAsync(status);
        return mock.Object;
    }
}
