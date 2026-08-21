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
if (passed == 0) throw new InvalidOperationException($"Unknown test group: {group}");
Console.WriteLine($"Process runner tests passed ({passed} checks).");

static async Task TestRetainedOutputHandleAsync()
{
    var repoRoot = Directory.GetCurrentDirectory();
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
    var fixture = Path.Combine(Directory.GetCurrentDirectory(), "tests", "fixtures", "ExitWithCode.ps1");
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
    var fixture = Path.Combine(Directory.GetCurrentDirectory(), "tests", "fixtures", "WaitUntilCancelled.ps1");
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
    var fixture = Path.Combine(Directory.GetCurrentDirectory(), "tests", "fixtures", "WaitUntilCancelled.ps1");
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

static string ResolvePowerShell()
{
    var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
    if (!File.Exists(path)) throw new FileNotFoundException("PowerShell 7 is required for tests.", path);
    return path;
}

static string Quote(string value) => $"\"{value.Replace("\"", "\\\"")}\"";

static void Assert(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}
