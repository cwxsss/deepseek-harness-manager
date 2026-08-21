using System.Diagnostics;
using System.Text;

namespace HarnessControl;

internal enum ProcessCompletionReason
{
    Exited,
    Cancelled,
    TimedOut,
}

internal sealed record PowerShellProcessResult(int ExitCode, ProcessCompletionReason Reason);

internal sealed record ProcessIdentity(int ProcessId, long StartTimeUtcTicks, string ExecutablePath)
{
    public static ProcessIdentity Capture(Process process, string executablePath) => new(
        process.Id,
        process.StartTime.ToUniversalTime().Ticks,
        Path.GetFullPath(executablePath));
}

internal sealed class ProcessTerminationException : Exception
{
    public ProcessIdentity Identity { get; }

    public ProcessTerminationException(string message, ProcessIdentity identity) : base(message)
    {
        Identity = identity;
    }
}

internal sealed class PowerShellProcessRunner
{
    private static readonly TimeSpan OutputDrainTimeout = TimeSpan.FromMilliseconds(500);
    private readonly string _powerShellPath;
    private readonly Action<string> _append;

    public PowerShellProcessRunner(string powerShellPath, Action<string> append)
    {
        _powerShellPath = powerShellPath;
        _append = append;
    }

    public async Task<PowerShellProcessResult> RunAsync(
        string scriptPath,
        string arguments,
        string action,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var info = new ProcessStartInfo
        {
            FileName = _powerShellPath,
            Arguments = $"-NoProfile -OutputFormat Text -ExecutionPolicy Bypass -File \"{scriptPath}\" {arguments}",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
            CreateNoWindow = true,
        };

        using var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        var exited = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var outputClosed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var errorClosed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        DataReceivedEventHandler outputHandler = (_, eventArgs) =>
        {
            if (eventArgs.Data is null) outputClosed.TrySetResult();
            else _append(eventArgs.Data);
        };
        DataReceivedEventHandler errorHandler = (_, eventArgs) =>
        {
            if (eventArgs.Data is null) errorClosed.TrySetResult();
            else _append($"[命令输出] {eventArgs.Data}");
        };
        EventHandler exitHandler = (_, _) => exited.TrySetResult(process.ExitCode);

        process.OutputDataReceived += outputHandler;
        process.ErrorDataReceived += errorHandler;
        process.Exited += exitHandler;

        if (!process.Start()) throw new InvalidOperationException("无法启动 PowerShell。");
        var processIdentity = ProcessIdentity.Capture(process, _powerShellPath);
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        if (process.HasExited) exited.TrySetResult(process.ExitCode);

        try
        {
            var cancellationTask = Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            var timeoutTask = Task.Delay(timeout);
            var completed = await Task.WhenAny(exited.Task, cancellationTask, timeoutTask);

            if (completed == exited.Task)
            {
                var exitCode = await exited.Task;
                await DrainOutputAsync(outputClosed.Task, errorClosed.Task);
                return new PowerShellProcessResult(exitCode, ProcessCompletionReason.Exited);
            }

            var reason = completed == cancellationTask
                ? ProcessCompletionReason.Cancelled
                : ProcessCompletionReason.TimedOut;
            TryStopProcess(process);
            await Task.WhenAny(exited.Task, Task.Delay(TimeSpan.FromSeconds(2)));
            if (!process.HasExited)
            {
                throw new ProcessTerminationException(
                    $"{action}已请求{(reason == ProcessCompletionReason.Cancelled ? "取消" : "超时中止")}，但 PowerShell 进程仍在运行；为避免并发操作，管理器不会恢复其他按钮。",
                    processIdentity);
            }
            var terminatedExitCode = process.HasExited ? process.ExitCode : -1;
            await DrainOutputAsync(outputClosed.Task, errorClosed.Task);
            return new PowerShellProcessResult(terminatedExitCode, reason);
        }
        finally
        {
            try { process.CancelOutputRead(); }
            catch (InvalidOperationException) { }
            try { process.CancelErrorRead(); }
            catch (InvalidOperationException) { }
            process.OutputDataReceived -= outputHandler;
            process.ErrorDataReceived -= errorHandler;
            process.Exited -= exitHandler;
        }
    }

    private async Task DrainOutputAsync(Task outputClosed, Task errorClosed)
    {
        var allOutputClosed = Task.WhenAll(outputClosed, errorClosed);
        if (await Task.WhenAny(allOutputClosed, Task.Delay(OutputDrainTimeout)) != allOutputClosed)
        {
            _append("[诊断] 直接 PowerShell 已退出，但后台子进程仍持有输出管道；管理器按直接进程结果完成操作。");
        }
    }

    private static void TryStopProcess(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception) { }
    }

    public static async Task<bool> TryTerminateProcessTreeAsync(ProcessIdentity identity, TimeSpan timeout)
    {
        try
        {
            using var process = Process.GetProcessById(identity.ProcessId);
            if (process.HasExited) return true;
            if (!MatchesIdentity(process, identity)) return true;
            process.Kill(entireProcessTree: true);
            using var cancellation = new CancellationTokenSource(timeout);
            try
            {
                await process.WaitForExitAsync(cancellation.Token);
                return true;
            }
            catch (OperationCanceledException)
            {
                return process.HasExited;
            }
        }
        catch (ArgumentException)
        {
            return true;
        }
        catch (InvalidOperationException)
        {
            return true;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    private static bool MatchesIdentity(Process process, ProcessIdentity identity)
    {
        try
        {
            if (process.StartTime.ToUniversalTime().Ticks != identity.StartTimeUtcTicks) return false;
            var actualPath = process.MainModule?.FileName;
            if (string.IsNullOrWhiteSpace(actualPath)) return false;
            return string.Equals(
                Path.GetFullPath(actualPath),
                Path.GetFullPath(identity.ExecutablePath),
                StringComparison.OrdinalIgnoreCase);
        }
        catch (InvalidOperationException)
        {
            return false;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }
}
