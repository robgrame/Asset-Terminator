using AssetTerminator.Api.Services;
using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using Microsoft.Extensions.Logging.Abstractions;
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

    private IntakeService Create()
    {
        _sla.Setup(s => s.ComputeDueAt(It.IsAny<AssetCategory>(), It.IsAny<DateTimeOffset>()))
            .Returns<AssetCategory, DateTimeOffset>((_, now) => now.AddDays(7));
        return new IntakeService(_store.Object, _audit.Object, _workflow.Object, _sla.Object, _telemetry.Object, NullLogger<IntakeService>.Instance);
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
}
