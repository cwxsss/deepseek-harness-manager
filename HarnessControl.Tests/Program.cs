using System.Collections.Concurrent;
using System.Diagnostics;
using HarnessControl;

var group = args.Length == 0 ? "all" : args[0];
var passed = 0;

if (group is "all" or "retained-output")
{
    await TestRetainedOutputHandleAsync();
    passed++;
}
if (group is "all" or "exit-code")
{
    await TestNonZeroExitCodeAsync();
    passed++;
}
if (group is "all" or "cancellation")
{
    await TestCancellationAsync();
    passed++;
}
if (group is "all" or "timeout")
{
    await TestTimeoutAsync();
    passed++;
}
if (group is "all" or "ui-state")
{
    TestOperationUiStates();
    TestInstallationConditionDetection();
    await TestStopWaitsForActiveOperationAsync();
    await TestFinalizationForEveryOutcomeAsync();
    passed += 16;
}
if (passed == 0) throw new InvalidOperationException($"Unknown test group: {group}");
Console.WriteLine($"Process runner tests passed ({passed} checks).");

static async Task TestRetainedOutputHandleAsync()
{
    var repoRoot = FindRepoRoot();
    var fixture = Path.Combine(repoRoot, "tests", "fixtures", "RetainedOutputHandle.ps1");
    var testRoot = Path.Combine(Path.GetTempPath(), $"dsh-process-runner-{Guid.NewGuid():N}");
    var pidFile = Path.Combine(testRoot, "child.pid");
    var childPid = 0;
    Directory.CreateDirectory(testRoot);

    try
    {
        var output = new ConcurrentQueue<string>();
        var runner = new PowerShellProcessRunner(ResolvePowerShell(), output.Enqueue);
        var stopwatch = Stopwatch.StartNew();
        var result = await runner.RunAsync(
            fixture,
            $"-PidFile {Quote(pidFile)}",
            "安装",
            TimeSpan.FromSeconds(10),
            CancellationToken.None);
        stopwatch.Stop();

        childPid = int.Parse(await File.ReadAllTextAsync(pidFile));
        Assert(result.ExitCode == 0, $"父 PowerShell 的退出码应为 0，实际为 {result.ExitCode}");
        Assert(stopwatch.Elapsed < TimeSpan.FromSeconds(5), $"后台子进程持有输出句柄时执行器仍须在五秒内返回，实际 {stopwatch.Elapsed}");
        Assert(!Process.GetProcessById(childPid).HasExited, "执行器不得误杀已分离的服务子进程");
        Assert(output.Any(line => line.Contains("输出管道", StringComparison.Ordinal)), "有界输出收尾必须记录输出管道仍被后台子进程持有");
    }
    finally
    {
        if (childPid > 0)
        {
            try { Process.GetProcessById(childPid).Kill(entireProcessTree: true); }
            catch (ArgumentException) { }
        }
        try { Directory.Delete(testRoot, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

static async Task TestNonZeroExitCodeAsync()
{
    var fixture = Path.Combine(FindRepoRoot(), "tests", "fixtures", "ExitWithCode.ps1");
    var runner = new PowerShellProcessRunner(ResolvePowerShell(), _ => { });
    var result = await runner.RunAsync(
        fixture,
        "-Code 23",
        "测试失败",
        TimeSpan.FromSeconds(5),
        CancellationToken.None);

    Assert(result.ExitCode == 23, $"必须传播非零退出码 23，实际为 {result.ExitCode}");
    Assert(result.Reason == ProcessCompletionReason.Exited, $"非零退出仍属于进程正常结束，实际为 {result.Reason}");
}

static async Task TestCancellationAsync()
{
    var fixture = Path.Combine(FindRepoRoot(), "tests", "fixtures", "WaitUntilCancelled.ps1");
    using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(300));
    var runner = new PowerShellProcessRunner(ResolvePowerShell(), _ => { });
    var stopwatch = Stopwatch.StartNew();
    var result = await runner.RunAsync(
        fixture,
        string.Empty,
        "取消测试",
        TimeSpan.FromSeconds(8),
        cancellation.Token);
    stopwatch.Stop();

    Assert(result.Reason == ProcessCompletionReason.Cancelled, $"必须区分用户取消，实际为 {result.Reason}");
    Assert(stopwatch.Elapsed < TimeSpan.FromSeconds(3), $"取消必须在三秒内结束，实际 {stopwatch.Elapsed}");
}

static async Task TestTimeoutAsync()
{
    var fixture = Path.Combine(FindRepoRoot(), "tests", "fixtures", "WaitUntilCancelled.ps1");
    var runner = new PowerShellProcessRunner(ResolvePowerShell(), _ => { });
    var stopwatch = Stopwatch.StartNew();
    var result = await runner.RunAsync(
        fixture,
        string.Empty,
        "超时测试",
        TimeSpan.FromMilliseconds(300),
        CancellationToken.None);
    stopwatch.Stop();

    Assert(result.Reason == ProcessCompletionReason.TimedOut, $"必须区分操作超时，实际为 {result.Reason}");
    Assert(stopwatch.Elapsed < TimeSpan.FromSeconds(3), $"超时必须在三秒内结束，实际 {stopwatch.Elapsed}");
}

static void TestOperationUiStates()
{
    var running = OperationUiState.ForRunning("安装", allowStop: true);
    Assert(!running.Install && !running.Start && running.Stop && !running.Update && !running.Uninstall,
        "安装进行中只能使用关闭按钮");

    var stopping = OperationUiState.ForStopping();
    Assert(!stopping.Install && !stopping.Start && !stopping.Stop && !stopping.Update && !stopping.Uninstall,
        "正在关闭时所有按钮必须暂时禁用");

    var installedAndRunning = OperationUiState.ForIdle(InstallationCondition.Complete, httpStatus: 200);
    Assert(installedAndRunning.Install && !installedAndRunning.Start && installedAndRunning.Stop &&
           installedAndRunning.Update && installedAndRunning.Uninstall,
        "安装完成并运行后必须启用重新安装、关闭、更新和卸载");
    Assert(!installedAndRunning.Status.Contains("正在", StringComparison.Ordinal), "安装完成后状态不得残留正在操作文案");

    var installedAndStopped = OperationUiState.ForIdle(InstallationCondition.Complete, httpStatus: 0);
    Assert(installedAndStopped.Install && installedAndStopped.Start && !installedAndStopped.Stop &&
           installedAndStopped.Update && installedAndStopped.Uninstall,
        "已安装但未运行时必须启用重新安装、启动、更新和卸载");

    var incomplete = OperationUiState.ForIdle(InstallationCondition.Incomplete, httpStatus: 0);
    Assert(incomplete.Install && !incomplete.Start && !incomplete.Stop && !incomplete.Update && incomplete.Uninstall,
        "残缺安装必须保留修复安装和卸载入口，不能启用启动或更新");

    var notInstalled = OperationUiState.ForIdle(InstallationCondition.None, httpStatus: 0);
    Assert(notInstalled.Install && !notInstalled.Start && !notInstalled.Stop && !notInstalled.Update && !notInstalled.Uninstall,
        "未安装时只能使用安装按钮");

    var stopOverridesInstall = OperationUiState.ForActivity("安装", allowStop: true, stopInProgress: true);
    Assert(!stopOverridesInstall.Install && !stopOverridesInstall.Start && !stopOverridesInstall.Stop &&
           !stopOverridesInstall.Update && !stopOverridesInstall.Uninstall && stopOverridesInstall.Status.Contains("正在关闭", StringComparison.Ordinal),
        "取消安装并关闭时，正在关闭必须覆盖正在安装且所有按钮保持禁用");
}

static async Task TestStopWaitsForActiveOperationAsync()
{
    using var gate = new SemaphoreSlim(1, 1);
    await gate.WaitAsync();
    var stopStarted = false;
    var stopTask = OperationStopCoordinator.RunAfterActiveOperationAsync(gate, () =>
    {
        stopStarted = true;
        return Task.CompletedTask;
    });

    await Task.Delay(200);
    Assert(!stopStarted, "关闭操作不得与尚未收尾的安装/更新并行执行");
    gate.Release();
    await stopTask;
    Assert(stopStarted, "原操作释放 gate 后必须执行关闭");
    Assert(gate.Wait(0), "关闭完成后必须释放操作 gate");
    gate.Release();
}

static void TestInstallationConditionDetection()
{
    var root = Path.Combine(Path.GetTempPath(), $"dsh-install-state-{Guid.NewGuid():N}");
    var harnessRoot = Path.Combine(root, "DeepSeekHarness");
    var profileRoot = Path.Combine(root, "profiles");
    var pluginRoot = Path.Combine(root, "local-plugins");
    try
    {
        Assert(InstallationConditionDetector.Detect(harnessRoot, profileRoot, pluginRoot) == InstallationCondition.None,
            "不存在任何目录时必须判定为未安装");

        Directory.CreateDirectory(harnessRoot);
        Assert(InstallationConditionDetector.Detect(harnessRoot, profileRoot, pluginRoot) == InstallationCondition.Incomplete,
            "仅创建 Harness 根目录时必须判定为残缺安装");

        foreach (var file in new[]
        {
            Path.Combine(harnessRoot, "node-runtime", "node-v22.17.1-win-x64", "node.exe"),
            Path.Combine(harnessRoot, "deepseek-harness-launcher", "Start-DeepSeekHarness.ps1"),
            Path.Combine(harnessRoot, "deepseek-harness-launcher", "Stop-DeepSeekHarness.ps1"),
            Path.Combine(harnessRoot, "deepseek-harness-launcher", "Update-DeepSeekHarness.ps1"),
            Path.Combine(profileRoot, "node_modules", "@deepseek-ai", "dsh", "package.json"),
            Path.Combine(profileRoot, "web", "package.json"),
            Path.Combine(pluginRoot, "packages", "sss-dsh-billing-0.1.5.tgz"),
            Path.Combine(pluginRoot, "packages", "sss-dsh-codex-reasoning-0.1.2.tgz"),
        })
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, "test");
        }
        Assert(InstallationConditionDetector.Detect(harnessRoot, profileRoot, pluginRoot) == InstallationCondition.Complete,
            "所有运行必需文件存在时必须判定为完整安装");
    }
    finally
    {
        if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
    }
}

static async Task TestFinalizationForEveryOutcomeAsync()
{
    using var cancelled = new CancellationTokenSource();
    cancelled.Cancel();
    var scenarios = new (string Name, Func<Task> Operation)[]
    {
        ("success", () => Task.CompletedTask),
        ("nonzero", () => Task.CompletedTask),
        ("exception", () => Task.FromException(new InvalidOperationException("expected"))),
        ("timeout", () => Task.FromException(new TimeoutException("expected"))),
        ("cancelled", () => Task.FromCanceled(cancelled.Token)),
    };

    foreach (var scenario in scenarios)
    {
        var finalized = 0;
        OperationUiState? finalState = null;
        try
        {
            await OperationExecutionCoordinator.RunWithFinalizerAsync(
                scenario.Operation,
                () =>
                {
                    finalized++;
                    finalState = OperationUiState.ForIdle(InstallationCondition.Complete, httpStatus: 200);
                    return Task.CompletedTask;
                });
        }
        catch (Exception) when (scenario.Name is "exception" or "timeout" or "cancelled")
        {
        }

        Assert(finalized == 1, $"{scenario.Name} 结果必须且只能执行一次最终收尾");
        Assert(finalState is { Install: true, Start: false, Stop: true, Update: true, Uninstall: true },
            $"{scenario.Name} 收尾后必须恢复运行中 Harness 的重新安装、关闭、更新和卸载按钮");
    }
}

static string ResolvePowerShell()
{
    var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
    if (!File.Exists(path)) throw new FileNotFoundException("PowerShell 7 is required for tests.", path);
    return path;
}

static string FindRepoRoot()
{
    for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
    {
        if (File.Exists(Path.Combine(directory.FullName, "tests", "fixtures", "RetainedOutputHandle.ps1")))
            return directory.FullName;
    }
    throw new DirectoryNotFoundException($"Unable to locate repository root from {AppContext.BaseDirectory}.");
}

static string Quote(string value) => $"\"{value.Replace("\"", "\\\"")}\"";

static void Assert(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}
