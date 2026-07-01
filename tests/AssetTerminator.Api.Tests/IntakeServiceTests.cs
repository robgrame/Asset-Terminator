using AssetTerminator.Api.Services;
using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Options;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Moq;

namespace AssetTerminator.Api.Tests;

/// <summary>
/// Unit tests for inbound validation and idempotency of the decommission intake.
/// </summary>
public sealed class IntakeServiceTests
{
    private readonly Mock<IStateStore> _store = new();
    private readonly Mock<IAuditWriter> _audit = new();
    private readonly Mock<IWorkflowStarter> _workflow = new();
    private readonly Mock<ISlaCalculator> _sla = new();
    private readonly Mock<IOperationalTelemetry> _telemetry = new();
    private PreWipeOptions _preWipe = new();

    private IntakeService Create()
    {
        _sla.Setup(s => s.ComputeDueAt(It.IsAny<AssetCategory>(), It.IsAny<DateTimeOffset>()))
            .Returns<AssetCategory, DateTimeOffset>((_, now) => now.AddDays(7));
        return new IntakeService(_store.Object, _audit.Object, _workflow.Object, _sla.Object, _telemetry.Object,
            Options.Create(_preWipe), NullLogger<IntakeService>.Instance);
    }

    private static DecommissionRequest ValidRequest() => new()
    {
        RequestId = "req-1",
        AssetId = "asset-1",
        DeviceName = "PC-1",
        DeviceType = DeviceType.Windows,
        AssetCategory = AssetCategory.Standard,
        RequestedActions = [DecommissionTarget.EntraId, DecommissionTarget.Wipe]
    };

    [Fact]
    public async Task MissingRequestId_IsRejected()
    {
        var req = ValidRequest();
        req.RequestId = "";

        var result = await Create().SubmitAsync(req, "{}", CancellationToken.None);

        Assert.False(result.Accepted);
        Assert.NotNull(result.Error);
        _workflow.Verify(w => w.StartAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task MissingDeviceNameAndSerial_IsRejected()
    {
        var req = ValidRequest();
        req.DeviceName = null;
        req.SerialNumber = null;

        var result = await Create().SubmitAsync(req, "{}", CancellationToken.None);

        Assert.False(result.Accepted);
    }

    [Fact]
    public async Task ValidNewRequest_StartsWorkflowOnce()
    {
        _store.Setup(s => s.GetOrCreateAsync(It.IsAny<DecommissionRecord>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync((DecommissionRecord r, CancellationToken _) => (r, true));

        var result = await Create().SubmitAsync(ValidRequest(), "{}", CancellationToken.None);

        Assert.True(result.Accepted);
        Assert.True(result.Created);
        _workflow.Verify(w => w.StartAsync("req-1", It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task DuplicateRequest_IsIdempotentAndDoesNotRestartWorkflow()
    {
        var existing = new DecommissionRecord { RequestId = "req-1", CorrelationId = "existing-corr" };
        _store.Setup(s => s.GetOrCreateAsync(It.IsAny<DecommissionRecord>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync((existing, false));

        var result = await Create().SubmitAsync(ValidRequest(), "{}", CancellationToken.None);

        Assert.True(result.Accepted);
        Assert.False(result.Created);
        Assert.Equal("existing-corr", result.CorrelationId);
        _workflow.Verify(w => w.StartAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task WindowsTerminateWipe_AutoInjectsPreWipeActions()
    {
        DecommissionRecord? captured = null;
        _store.Setup(s => s.GetOrCreateAsync(It.IsAny<DecommissionRecord>(), It.IsAny<CancellationToken>()))
            .Callback((DecommissionRecord r, CancellationToken _) => captured = r)
            .ReturnsAsync((DecommissionRecord r, CancellationToken _) => (r, true));

        var req = ValidRequest();
        req.SerialNumber = "SN-123";
        req.RequestedActions = [DecommissionTarget.Wipe];

        var result = await Create().SubmitAsync(req, "{}", CancellationToken.None);

        Assert.True(result.Accepted);
        var targets = captured!.Actions.Select(a => a.Target).ToHashSet();
        Assert.Contains(DecommissionTarget.Autopilot, targets);
        Assert.Contains(DecommissionTarget.LicenseRemoval, targets);
        Assert.Contains(DecommissionTarget.BiosPasswordRemoval, targets);
        Assert.Contains(DecommissionTarget.Wipe, targets);
    }

    [Fact]
    public async Task WindowsTerminateWipe_WithoutSerial_DoesNotInjectAutopilot()
    {
        DecommissionRecord? captured = null;
        _store.Setup(s => s.GetOrCreateAsync(It.IsAny<DecommissionRecord>(), It.IsAny<CancellationToken>()))
            .Callback((DecommissionRecord r, CancellationToken _) => captured = r)
            .ReturnsAsync((DecommissionRecord r, CancellationToken _) => (r, true));

        var req = ValidRequest();
        req.SerialNumber = null;
        req.DeviceName = "PC-1";
        req.RequestedActions = [DecommissionTarget.Wipe];

        await Create().SubmitAsync(req, "{}", CancellationToken.None);

        var targets = captured!.Actions.Select(a => a.Target).ToHashSet();
        Assert.DoesNotContain(DecommissionTarget.Autopilot, targets);
        Assert.Contains(DecommissionTarget.LicenseRemoval, targets);
    }

    [Fact]
    public async Task RetireDisposition_InjectsRetireAndOmitsWipe()
    {
        DecommissionRecord? captured = null;
        _store.Setup(s => s.GetOrCreateAsync(It.IsAny<DecommissionRecord>(), It.IsAny<CancellationToken>()))
            .Callback((DecommissionRecord r, CancellationToken _) => captured = r)
            .ReturnsAsync((DecommissionRecord r, CancellationToken _) => (r, true));

        var req = ValidRequest();
        req.DispositionType = DispositionType.Retire;
        req.RequestedActions = [DecommissionTarget.EntraId, DecommissionTarget.Intune];

        var result = await Create().SubmitAsync(req, "{}", CancellationToken.None);

        Assert.True(result.Accepted);
        var targets = captured!.Actions.Select(a => a.Target).ToHashSet();
        Assert.Contains(DecommissionTarget.Retire, targets);
        Assert.DoesNotContain(DecommissionTarget.Wipe, targets);
        Assert.DoesNotContain(DecommissionTarget.Autopilot, targets);
    }

    [Fact]
    public async Task RetireDisposition_WithWipeAction_IsRejected()
    {
        var req = ValidRequest();
        req.DispositionType = DispositionType.Retire;
        req.RequestedActions = [DecommissionTarget.EntraId, DecommissionTarget.Wipe];

        var result = await Create().SubmitAsync(req, "{}", CancellationToken.None);

        Assert.False(result.Accepted);
        Assert.NotNull(result.Error);
    }

    [Fact]
    public async Task PreWipeDisabled_DoesNotInjectPreventiveActions()
    {
        _preWipe = new PreWipeOptions
        {
            DeleteFromAutopilot = false,
            RemoveEnterpriseLicense = false,
            RemoveBiosPassword = false
        };
        DecommissionRecord? captured = null;
        _store.Setup(s => s.GetOrCreateAsync(It.IsAny<DecommissionRecord>(), It.IsAny<CancellationToken>()))
            .Callback((DecommissionRecord r, CancellationToken _) => captured = r)
            .ReturnsAsync((DecommissionRecord r, CancellationToken _) => (r, true));

        var req = ValidRequest();
        req.SerialNumber = "SN-123";
        req.RequestedActions = [DecommissionTarget.Wipe];

        await Create().SubmitAsync(req, "{}", CancellationToken.None);

        var targets = captured!.Actions.Select(a => a.Target).ToHashSet();
        Assert.DoesNotContain(DecommissionTarget.Autopilot, targets);
        Assert.DoesNotContain(DecommissionTarget.LicenseRemoval, targets);
        Assert.DoesNotContain(DecommissionTarget.BiosPasswordRemoval, targets);
    }
}
