using AssetTerminator.Contracts;
using AssetTerminator.Core.Domain;
using AssetTerminator.Core.Guardrails;
using AssetTerminator.Core.Options;
using Microsoft.Extensions.Options;

namespace AssetTerminator.Guardrails;

public sealed class EncryptionGuardrail(IOptionsMonitor<GuardrailsOptions> options) : GuardrailBase(options)
{
    public const string GuardrailId = "encryption";

    public override string Id => GuardrailId;

    public override Task<GuardrailResult> EvaluateAsync(DeviceContext context, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();

        var result = context.DeviceType switch
        {
            DeviceType.Windows => EvaluateWindows(context),
            DeviceType.MacOS => EvaluateMacOS(context),
            DeviceType.iOS or DeviceType.Android => Pass(),
            _ => Fail($"Encryption state for device type '{context.DeviceType}' cannot be evaluated.")
        };

        return Task.FromResult(result);
    }

    private GuardrailResult EvaluateWindows(DeviceContext context)
    {
        if (context.IsEncrypted is null)
        {
            return Fail("Windows encryption state is unknown; failing closed.");
        }

        return context.IsEncrypted == true || context.HasRecoveryKeyEscrowed == true
            ? Pass()
            : Fail("Windows device is not encrypted and no BitLocker recovery key is escrowed.");
    }

    private GuardrailResult EvaluateMacOS(DeviceContext context)
    {
        if (context.IsEncrypted is null)
        {
            return Fail("macOS FileVault state is unknown; failing closed.");
        }

        return context.IsEncrypted == true
            ? Pass()
            : Fail("macOS device does not have FileVault enabled.");
    }
}
