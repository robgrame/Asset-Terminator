using AssetTerminator.Contracts;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Guardrails;
using AssetTerminator.Core.Options;
using AssetTerminator.Guardrails;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Moq;

namespace AssetTerminator.Guardrails.Tests;

public sealed class EncryptionGuardrailTests
{
    [Fact]
    public async Task WindowsEncryptedPasses()
    {
        var result = await EvaluateEncryptionAsync(DeviceType.Windows, isEncrypted: true, hasRecoveryKeyEscrowed: false);

        Assert.True(result.Passed);
    }

    [Fact]
    public async Task WindowsUnencryptedWithEscrowedRecoveryKeyPasses()
    {
        var result = await EvaluateEncryptionAsync(DeviceType.Windows, isEncrypted: false, hasRecoveryKeyEscrowed: true);

        Assert.True(result.Passed);
    }

    [Fact]
    public async Task WindowsUnencryptedWithoutEscrowedRecoveryKeyBlocks()
    {
        var result = await EvaluateEncryptionAsync(DeviceType.Windows, isEncrypted: false, hasRecoveryKeyEscrowed: false);

        Assert.False(result.Passed);
        Assert.True(result.Mandatory);
        Assert.Equal(GuardrailSeverity.Blocking, result.Severity);
    }

    [Fact]
    public async Task MacOSFileVaultOffBlocks()
    {
        var result = await EvaluateEncryptionAsync(DeviceType.MacOS, isEncrypted: false, hasRecoveryKeyEscrowed: null);

        Assert.False(result.Passed);
        Assert.Equal(GuardrailSeverity.Blocking, result.Severity);
    }

    [Fact]
    public async Task IosPasses()
    {
        var result = await EvaluateEncryptionAsync(DeviceType.iOS, isEncrypted: null, hasRecoveryKeyEscrowed: null);

        Assert.True(result.Passed);
    }

    [Fact]
    public async Task NullEncryptionStateFailsClosed()
    {
        var result = await EvaluateEncryptionAsync(DeviceType.Windows, isEncrypted: null, hasRecoveryKeyEscrowed: false);

        Assert.False(result.Passed);
        Assert.Contains("unknown", result.Reason, StringComparison.OrdinalIgnoreCase);
    }

    private static Task<GuardrailResult> EvaluateEncryptionAsync(DeviceType deviceType, bool? isEncrypted, bool? hasRecoveryKeyEscrowed)
    {
        var guardrail = new EncryptionGuardrail(TestOptionsMonitor.Create(new GuardrailsOptions()));
        var context = TestData.Device(deviceType);
        context.IsEncrypted = isEncrypted;
        context.HasRecoveryKeyEscrowed = hasRecoveryKeyEscrowed;

        return guardrail.EvaluateAsync(context, CancellationToken.None);
    }
}

public sealed class InactivityGuardrailTests
{
    [Fact]
    public async Task RecentlyActiveBlocks()
    {
        var result = await EvaluateAsync(DateTimeOffset.UtcNow.AddDays(-10));

        Assert.False(result.Passed);
        Assert.Contains("active too recently", result.Reason, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task InactiveBeyondThresholdPasses()
    {
        var result = await EvaluateAsync(DateTimeOffset.UtcNow.AddDays(-31));

        Assert.True(result.Passed);
    }

    [Fact]
    public async Task NullLastActivityBlocks()
    {
        var result = await EvaluateAsync(null);

        Assert.False(result.Passed);
        Assert.Contains("unknown", result.Reason, StringComparison.OrdinalIgnoreCase);
    }

    private static Task<GuardrailResult> EvaluateAsync(DateTimeOffset? lastActivityUtc)
    {
        var guardrail = new InactivityGuardrail(TestOptionsMonitor.Create(new GuardrailsOptions
        {
            Items =
            {
                [InactivityGuardrail.GuardrailId] = new GuardrailOptions { Threshold = 30 }
            }
        }));

        var context = TestData.Device(DeviceType.Windows);
        context.LastActivityUtc = lastActivityUtc;

        return guardrail.EvaluateAsync(context, CancellationToken.None);
    }
}

public sealed class CriticalGroupGuardrailTests
{
    [Fact]
    public async Task DeviceInBlockedGroupBlocks()
    {
        var result = await EvaluateAsync(["Standard", "Privileged Devices"]);

        Assert.False(result.Passed);
        Assert.Equal(GuardrailSeverity.Blocking, result.Severity);
    }

    [Fact]
    public async Task DeviceNotInBlockedGroupPasses()
    {
        var result = await EvaluateAsync(["Standard"]);

        Assert.True(result.Passed);
    }

    private static Task<GuardrailResult> EvaluateAsync(IReadOnlyList<string> groupMemberships)
    {
        var guardrail = new CriticalGroupGuardrail(TestOptionsMonitor.Create(new GuardrailsOptions
        {
            Items =
            {
                [CriticalGroupGuardrail.GuardrailId] = new GuardrailOptions
                {
                    Settings = new Dictionary<string, string>
                    {
                        ["BlockedGroups"] = "Privileged Devices, Executive Devices"
                    }
                }
            }
        }));

        var context = TestData.Device(DeviceType.Windows);
        context.GroupMemberships = groupMemberships;

        return guardrail.EvaluateAsync(context, CancellationToken.None);
    }
}

public sealed class GuardrailEngineTests
{
    [Fact]
    public async Task MandatoryGuardrailFailureMakesEvaluationNotAllowed()
    {
        var engine = CreateEngine(new StubGuardrail("mandatory", GuardrailResult.Fail("mandatory", "blocked", GuardrailSeverity.Blocking, true, true)));

        var evaluation = await engine.EvaluateAsync(TestData.Device(DeviceType.Windows), null, CancellationToken.None);

        Assert.False(evaluation.Allowed);
        Assert.Single(evaluation.BlockingFailures);
    }

    [Fact]
    public async Task NonMandatoryGuardrailFailureStillAllowsEvaluation()
    {
        var engine = CreateEngine(new StubGuardrail("warning", GuardrailResult.Fail("warning", "warning", GuardrailSeverity.Warning, false, true)));

        var evaluation = await engine.EvaluateAsync(TestData.Device(DeviceType.Windows), null, CancellationToken.None);

        Assert.True(evaluation.Allowed);
        Assert.Empty(evaluation.BlockingFailures);
    }

    [Fact]
    public async Task OverriddenGuardrailFailureIsConvertedToPassingWarning()
    {
        var engine = CreateEngine(new StubGuardrail("encryption", GuardrailResult.Fail("encryption", "blocked", GuardrailSeverity.Blocking, true, true)));

        var evaluation = await engine.EvaluateAsync(TestData.Device(DeviceType.Windows), new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "encryption" }, CancellationToken.None);

        var result = Assert.Single(evaluation.Results);
        Assert.True(result.Passed);
        Assert.True(evaluation.Allowed);
        Assert.Equal(GuardrailSeverity.Warning, result.Severity);
        Assert.StartsWith("[OVERRIDDEN]", result.Reason);
    }

    [Fact]
    public async Task ThrowingGuardrailFailsClosed()
    {
        var engine = CreateEngine(new ThrowingGuardrail("throws"));

        var evaluation = await engine.EvaluateAsync(TestData.Device(DeviceType.Windows), null, CancellationToken.None);

        var result = Assert.Single(evaluation.Results);
        Assert.False(result.Passed);
        Assert.True(result.Mandatory);
        Assert.False(evaluation.Allowed);
    }

    [Fact]
    public async Task DisabledGuardrailIsSkipped()
    {
        var engine = CreateEngine(
            new StubGuardrail("disabled", GuardrailResult.Fail("disabled", "should not run", GuardrailSeverity.Blocking, true, true)),
            options: new GuardrailsOptions
            {
                Items =
                {
                    ["disabled"] = new GuardrailOptions { Enabled = false }
                }
            });

        var evaluation = await engine.EvaluateAsync(TestData.Device(DeviceType.Windows), null, CancellationToken.None);

        Assert.Empty(evaluation.Results);
        Assert.True(evaluation.Allowed);
    }

    private static GuardrailEngine CreateEngine(IWipeGuardrail guardrail, GuardrailsOptions? options = null) =>
        new(
            [guardrail],
            TestOptionsMonitor.Create(options ?? new GuardrailsOptions()),
            NullLogger<GuardrailEngine>.Instance);
}

internal static class TestData
{
    public static DeviceContext Device(DeviceType deviceType) =>
        new()
        {
            RequestId = "request-1",
            CorrelationId = "correlation-1",
            DeviceType = deviceType,
            AssetCategory = AssetCategory.Standard
        };
}

internal sealed class StubGuardrail(string id, GuardrailResult result) : IWipeGuardrail
{
    public string Id => id;

    public Task<GuardrailResult> EvaluateAsync(DeviceContext context, CancellationToken ct) => Task.FromResult(result);
}

internal sealed class ThrowingGuardrail(string id) : IWipeGuardrail
{
    public string Id => id;

    public Task<GuardrailResult> EvaluateAsync(DeviceContext context, CancellationToken ct) =>
        throw new InvalidOperationException("boom");
}

internal static class TestOptionsMonitor
{
    public static IOptionsMonitor<T> Create<T>(T value)
    {
        var mock = new Mock<IOptionsMonitor<T>>();
        mock.SetupGet(m => m.CurrentValue).Returns(value);
        mock.Setup(m => m.Get(It.IsAny<string?>())).Returns(value);
        return mock.Object;
    }
}
