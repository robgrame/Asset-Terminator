using System.Diagnostics;
using System.Text;
using AssetTerminator.Core.Domain;

namespace AssetTerminator.Providers.DeviceActions;

/// <summary>Outcome of launching a local command/tool.</summary>
public sealed record CommandOutcome(bool Success, int ExitCode, string Output, bool TimedOut);

/// <summary>Launches a local executable/script (OEM tool, PowerShell, etc.) and captures its result.</summary>
public interface ILocalCommandRunner
{
    Task<CommandOutcome> RunAsync(CommandSpec spec, DeviceContext context, TimeSpan timeout, CancellationToken ct);
}

/// <summary>
/// Default <see cref="ILocalCommandRunner"/> that starts a process, applies the device-context
/// placeholder substitutions, enforces a timeout and captures stdout/stderr.
/// </summary>
public sealed class ProcessCommandRunner : ILocalCommandRunner
{
    public async Task<CommandOutcome> RunAsync(CommandSpec spec, DeviceContext context, TimeSpan timeout, CancellationToken ct)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = spec.FileName!,
            Arguments = Substitute(spec.Arguments ?? string.Empty, context),
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        if (!string.IsNullOrWhiteSpace(spec.WorkingDirectory))
        {
            startInfo.WorkingDirectory = spec.WorkingDirectory;
        }

        using var process = new Process { StartInfo = startInfo };
        var output = new StringBuilder();
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) output.AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) output.AppendLine(e.Data); };

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);

        try
        {
            await process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            TryKill(process);
            return new CommandOutcome(false, -1, output.ToString(), TimedOut: true);
        }

        var exitCode = process.ExitCode;
        var success = exitCode == 0 || spec.IgnoreExitCode;
        return new CommandOutcome(success, exitCode, output.ToString(), TimedOut: false);
    }

    private static string Substitute(string template, DeviceContext context) => template
        .Replace("{serialNumber}", context.SerialNumber ?? string.Empty, StringComparison.OrdinalIgnoreCase)
        .Replace("{deviceName}", context.DeviceName ?? string.Empty, StringComparison.OrdinalIgnoreCase)
        .Replace("{primaryUserUpn}", context.PrimaryUserUpn ?? string.Empty, StringComparison.OrdinalIgnoreCase);

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // best-effort cleanup
        }
    }
}
