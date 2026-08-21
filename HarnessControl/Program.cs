using System.Net;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;

namespace HarnessControl;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
    }
}

internal sealed class MainForm : Form
{
    private const string HarnessUrl = "http://127.0.0.1:3080/";
    private const string HarnessName = "DeepSeek Harness";
    private readonly Label _status = new() { AutoSize = true, Font = new Font(SystemFonts.DefaultFont, FontStyle.Bold) };
    private readonly Label _hint = new() { AutoSize = true, ForeColor = Color.DimGray };
    private readonly Button _install = CreateButton("安装 DeepSeek");
    private readonly Button _start = CreateButton("启动 DeepSeek");
    private readonly Button _stop = CreateButton("关闭 DeepSeek");
    private readonly Button _update = CreateButton("更新 DeepSeek");
    private readonly Button _uninstall = CreateButton("卸载 DeepSeek");
    private readonly TextBox _log = new()
    {
        Multiline = true,
        ReadOnly = true,
        ScrollBars = ScrollBars.Vertical,
        Dock = DockStyle.Fill,
        BackColor = Color.White,
        Font = new Font("Cascadia Mono", 9F),
    };
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private CancellationTokenSource? _activeCancellation;
    private string? _activeAction;
    private bool _activeAllowStop;
    private bool _stopInProgress;

    private static string HarnessRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeepSeekHarness");
    private static string ProfileRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dsh", "profiles");
    private static string LocalPluginRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dsh", "local-plugins");
    private static string LauncherRoot => Path.Combine(HarnessRoot, "deepseek-harness-launcher");
    private static string SupportRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeepSeekHarnessManager", "installer");

    public MainForm()
    {
        Text = "DeepSeek Harness 管理器";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = true;
        ClientSize = new Size(560, 590);

        var actions = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(18, 12, 18, 8),
            Height = 285,
        };
        actions.Controls.Add(_status);
        actions.Controls.Add(_hint);
        actions.Controls.Add(_install);
        actions.Controls.Add(_start);
        actions.Controls.Add(_stop);
        actions.Controls.Add(_update);
        actions.Controls.Add(_uninstall);

        var logPanel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(18, 0, 18, 16) };
        logPanel.Controls.Add(_log);
        Controls.Add(logPanel);
        Controls.Add(actions);

        _install.Click += async (_, _) => await InstallAsync();
        _start.Click += async (_, _) => await RunExclusiveAsync("启动", () => ExecutePowerShellAsync(LauncherPath("Start-DeepSeekHarness.ps1"), "-PassThru", "启动"), allowStop: true);
        _stop.Click += async (_, _) => await StopAsync();
        _update.Click += async (_, _) => await RunExclusiveAsync("更新", () => ExecutePowerShellAsync(LauncherPath("Update-DeepSeekHarness.ps1"), "-PassThru", "更新"), allowStop: true);
        _uninstall.Click += async (_, _) => await UninstallAsync();
        Shown += async (_, _) =>
        {
            await RefreshStatusAsync();
            Append("管理器已就绪。安装、启动、关闭、更新和卸载均会保留操作日志。");
        };
    }

    private static Button CreateButton(string text) => new()
    {
        Text = text,
        Width = 510,
        Height = 34,
        Margin = new Padding(0, 7, 0, 0),
        Font = new Font(SystemFonts.DefaultFont, FontStyle.Regular),
    };

    private static string LauncherPath(string script) => Path.Combine(LauncherRoot, script);

    private async Task InstallAsync()
    {
        var result = MessageBox.Show(
            "将安装或继续安装 DeepSeek Harness，并下载官方核心、官方 Web UI 与两个本地 SSS 插件。\n\n已存在的完整安装不会被覆盖。是否继续？",
            "确认安装", MessageBoxButtons.YesNo, MessageBoxIcon.Information, MessageBoxDefaultButton.Button2);
        if (result != DialogResult.Yes) return;

        if (HasBrokenInstallation())
        {
            var repair = MessageBox.Show(
                "检测到 Harness 安装结构或配置异常。继续前将删除错误安装并重新安装。\n\n不会删除本管理器 EXE。是否修复并继续？",
                "修复错误安装", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
            if (repair != DialogResult.Yes) return;
            await RunExclusiveAsync("修复错误安装", ClearBrokenInstallationAsync, allowStop: false);
            if (Directory.Exists(HarnessRoot) || Directory.Exists(ProfileRoot) || Directory.Exists(LocalPluginRoot)) return;
        }
        else if (HasIncompleteResidual())
        {
            var cleanup = MessageBox.Show(
                "检测到未完成安装遗留的配置目录。继续安装前，需要删除这部分不完整的配置和本地插件。\n\n不会删除管理器 EXE。是否清理并继续？",
                "清理未完成安装", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
            if (cleanup != DialogResult.Yes) return;
            await RunExclusiveAsync("清理未完成安装", ClearIncompleteResidualAsync, allowStop: false);
            if (Directory.Exists(ProfileRoot) || Directory.Exists(LocalPluginRoot)) return;
        }
        else if (HasExistingInstallation())
        {
            var replace = MessageBox.Show(
                "检测到已有 DeepSeek Harness。为确保核心、Web UI 和全局插件版本一致，本次安装将停止服务并替换现有 Harness 目录。\n\n将删除 %LOCALAPPDATA%\\DeepSeekHarness、%USERPROFILE%\\.dsh\\profiles 和 %USERPROFILE%\\.dsh\\local-plugins，不会删除本管理器 EXE。是否继续？",
                "替换现有安装", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
            if (replace != DialogResult.Yes) return;
            await RunExclusiveAsync("替换现有安装", ClearBrokenInstallationAsync, allowStop: false);
            if (Directory.Exists(HarnessRoot) || Directory.Exists(ProfileRoot) || Directory.Exists(LocalPluginRoot)) return;
        }

        await RunExclusiveAsync("安装", async () =>
        {
            Append("正在准备内置安装资源…");
            var installer = await Task.Run(EnsureInstallerPayload);
            Append("安装资源准备完成，开始安装或续装 DeepSeek Harness。");
            return await ExecutePowerShellAsync(installer, string.Empty, "安装");
        }, allowStop: true);
    }

    private async Task StopAsync()
    {
        if (_stopInProgress)
        {
            Append("关闭操作已经在执行，请等待其完成。");
            return;
        }

        if (_activeCancellation is not null)
        {
            _stopInProgress = true;
            Append($"正在取消“{_activeAction}”操作，随后关闭 DeepSeek…");
            try
            {
                _activeCancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // The active operation may have finished between the check and cancellation.
            }

            SetStoppingUi();
            try
            {
                await OperationStopCoordinator.RunAfterActiveOperationAsync(_operationGate, async () =>
                {
                    var stopExitCode = await ExecutePowerShellAsync(
                        LauncherPath("Stop-DeepSeekHarness.ps1"), "-PassThru", "关闭", CancellationToken.None);
                    Append(stopExitCode == 0
                        ? "关闭命令已完成。"
                        : $"关闭失败，退出码：{stopExitCode}。请查看上方日志。");
                });
            }
            catch (Exception ex)
            {
                Append($"关闭异常：{ex.Message}");
            }
            finally
            {
                _stopInProgress = false;
                if (_activeAction is null)
                {
                    await RefreshStatusSafelyAsync();
                }
            }
            return;
        }

        await _operationGate.WaitAsync();
        try
        {
            BeginOperation("关闭", allowStop: false);
            await ExecutePowerShellAsync(LauncherPath("Stop-DeepSeekHarness.ps1"), "-PassThru", "关闭");
        }
        finally
        {
            try
            {
                EndOperation();
            }
            finally
            {
                try { await RefreshStatusSafelyAsync(); }
                finally { _operationGate.Release(); }
            }
        }
    }

    private static bool HasIncompleteResidual() =>
        !Directory.Exists(HarnessRoot) && (Directory.Exists(ProfileRoot) || Directory.Exists(LocalPluginRoot));

    private static bool HasExistingInstallation() =>
        Directory.Exists(HarnessRoot) || Directory.Exists(ProfileRoot) || Directory.Exists(LocalPluginRoot);

    private static bool HasBrokenInstallation()
    {
        var dshPackage = Path.Combine(ProfileRoot, "node_modules", "@deepseek-ai", "dsh");
        if (HasUtf8Bom(Path.Combine(ProfileRoot, "web", "package.json"))) return true;
        if (!Directory.Exists(dshPackage)) return false;
        try { return (File.GetAttributes(dshPackage) & FileAttributes.ReparsePoint) == 0; }
        catch { return false; }
    }

    private async Task<int> ClearIncompleteResidualAsync()
        => await ClearInstallationTargetsAsync(new[] { ProfileRoot, LocalPluginRoot }, "清理未完成安装遗留目录");

    private async Task<int> ClearBrokenInstallationAsync()
        => await ClearInstallationTargetsAsync(new[] { HarnessRoot, ProfileRoot, LocalPluginRoot }, "清理错误安装目录");

    private async Task<int> ClearInstallationTargetsAsync(IEnumerable<string> targets, string operation)
    {
        await StopResidualHarnessProcessesAsync();
        var failures = new List<string>();
        foreach (var target in targets)
        {
            if (!Directory.Exists(target)) continue;
            try
            {
                Append($"正在{operation}：{target}");
                await DeleteDirectoryWithRetryAsync(target);
            }
            catch (Exception ex)
            {
                failures.Add($"{target}: {ex.Message}");
                Append($"清理失败：{target}；{ex.Message}");
            }
        }
        return failures.Count == 0 ? 0 : 1;
    }

    private async Task UninstallAsync()
    {
        var result = MessageBox.Show(
            "将停止服务并永久删除：\n\n• %LOCALAPPDATA%\\DeepSeekHarness\n• %USERPROFILE%\\.dsh\\profiles\n• %USERPROFILE%\\.dsh\\local-plugins\n• 旧版启动/关闭 VBS 入口\n\n不会删除本管理器 EXE。是否确认卸载？",
            "确认卸载 DeepSeek", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
        if (result != DialogResult.Yes) return;

        await RunExclusiveAsync("卸载", async () =>
        {
            var stopScript = LauncherPath("Stop-DeepSeekHarness.ps1");
            if (File.Exists(stopScript))
            {
                Append("正在停止 DeepSeek Harness 服务…");
                await ExecutePowerShellAsync(stopScript, "-PassThru", "关闭");
            }
            await StopResidualHarnessProcessesAsync();
            await Task.Delay(1000);

            var targets = new[] { HarnessRoot, ProfileRoot, LocalPluginRoot };
            var removed = new List<string>();
            var failures = new List<string>();
            foreach (var target in targets)
            {
                if (!Directory.Exists(target)) continue;
                try
                {
                    Append($"正在删除：{target}");
                    await DeleteDirectoryWithRetryAsync(target);
                    removed.Add(target);
                }
                catch (Exception ex)
                {
                    failures.Add($"{target}: {ex.Message}");
                    Append($"删除失败：{target}；{ex.Message}");
                }
            }

            foreach (var legacy in new[] { "启动 DeepSeek Harness.vbs", "关闭 DeepSeek Harness.vbs" })
            {
                var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), legacy);
                try { if (File.Exists(path)) File.Delete(path); }
                catch (Exception ex) { failures.Add($"{path}: {ex.Message}"); }
            }

            WriteUninstallReport(removed, failures);
            if (failures.Count > 0)
            {
                Append("卸载未完全完成，请查看桌面的“DeepSeek Harness 卸载报告.txt”。");
                return 1;
            }
            Append("卸载完成。管理器仍保留，可随时再次安装。");
            return 0;
        }, allowStop: false);
    }

    private async Task RunExclusiveAsync(string action, Func<Task<int>> operation, bool allowStop)
    {
        if (!await _operationGate.WaitAsync(0))
        {
            Append($"已有“{_activeAction ?? "其他"}”操作在执行；如需中止，请点击“关闭 DeepSeek”。");
            return;
        }

        await OperationExecutionCoordinator.RunWithFinalizerAsync(
            async () =>
            {
                try
                {
                    BeginOperation(action, allowStop);
                    Append($"========== {action} {HarnessName} ==========");
                    var exitCode = await operation();
                    if (_activeCancellation?.IsCancellationRequested == true)
                        Append($"{action}已取消。服务状态已重新检测。");
                    else if (exitCode == 0)
                        Append($"{action}完成。");
                    else
                        Append($"{action}失败，退出码：{exitCode}。请查看上方日志或桌面报告。");
                }
                catch (Exception ex)
                {
                    Append($"{action}异常：{ex.Message}");
                }
            },
            async () =>
            {
                try
                {
                    EndOperation();
                }
                finally
                {
                    try { await RefreshStatusSafelyAsync(); }
                    finally { _operationGate.Release(); }
                }
            });
    }

    private static bool HasUtf8Bom(string path)
    {
        if (!File.Exists(path)) return false;

        try
        {
            using var stream = File.OpenRead(path);
            return stream.ReadByte() == 0xEF && stream.ReadByte() == 0xBB && stream.ReadByte() == 0xBF;
        }
        catch
        {
            return false;
        }
    }

    private async Task<int> ExecutePowerShellAsync(
        string scriptPath,
        string arguments,
        string action,
        CancellationToken? cancellationToken = null)
    {
        if (!File.Exists(scriptPath))
        {
            Append($"未找到 {Path.GetFileName(scriptPath)}：{scriptPath}");
            return 1;
        }

        var token = cancellationToken ?? _activeCancellation?.Token ?? CancellationToken.None;
        var runner = new PowerShellProcessRunner(ResolvePowerShell(), Append);
        var runTask = runner.RunAsync(scriptPath, arguments, action, TimeSpan.FromMinutes(15), token);
        while (!runTask.IsCompleted)
        {
            await Task.WhenAny(runTask, Task.Delay(500));
            if (!runTask.IsCompleted) await RefreshStatusAsync();
        }

        var result = await runTask;
        if (result.Reason == ProcessCompletionReason.TimedOut)
            throw new TimeoutException($"{action}超过 15 分钟仍未完成，已中止本次操作。请查看日志后重试。");
        if (result.ExitCode != 0 && result.Reason != ProcessCompletionReason.Cancelled)
            AppendHarnessDiagnostics();
        return result.ExitCode;
    }

    private void AppendHarnessDiagnostics()
    {
        var stderrPath = Path.Combine(LauncherRoot, "deepseek-harness.stderr.log");
        if (!File.Exists(stderrPath)) return;
        try
        {
            var lines = File.ReadLines(stderrPath, Encoding.UTF8).TakeLast(80).ToArray();
            if (lines.Length == 0) return;
            Append("========== Harness 核心错误日志 ==========");
            foreach (var line in lines) Append($"[核心错误] {line}");
        }
        catch (Exception ex)
        {
            Append($"读取 Harness 核心错误日志失败：{ex.Message}");
        }
    }

    private string EnsureInstallerPayload()
    {
        var payload = Path.Combine(SupportRoot, "payload");
        var launcher = Path.Combine(payload, "launcher");
        var plugins = Path.Combine(payload, "plugins");
        Directory.CreateDirectory(launcher);
        Directory.CreateDirectory(plugins);

        ExtractResource("HarnessControl.Resources.Install.ps1", Path.Combine(SupportRoot, "Install-DeepSeekHarness.ps1"), textFile: true);
        ExtractResource("HarnessControl.Resources.Install.Completion.ps1", Path.Combine(SupportRoot, "Install.Completion.ps1"), textFile: true);
        ExtractResource("HarnessControl.Resources.Install.Target.ps1", Path.Combine(SupportRoot, "Install.Target.ps1"), textFile: true);
        ExtractResource("HarnessControl.Resources.Launcher.Common.ps1", Path.Combine(launcher, "Launcher.Common.ps1"), textFile: true);
        ExtractResource("HarnessControl.Resources.Version.Common.ps1", Path.Combine(launcher, "Version.Common.ps1"), textFile: true);
        ExtractResource("HarnessControl.Resources.Start.ps1", Path.Combine(launcher, "Start-DeepSeekHarness.ps1"), textFile: true);
        ExtractResource("HarnessControl.Resources.Stop.ps1", Path.Combine(launcher, "Stop-DeepSeekHarness.ps1"), textFile: true);
        ExtractResource("HarnessControl.Resources.Update.ps1", Path.Combine(launcher, "Update-DeepSeekHarness.ps1"), textFile: true);
        ExtractResource("HarnessControl.Resources.billing.tgz", Path.Combine(plugins, "sss-dsh-billing-0.1.5.tgz"), textFile: false);
        ExtractResource("HarnessControl.Resources.codex-reasoning.tgz", Path.Combine(plugins, "sss-dsh-codex-reasoning-0.1.2.tgz"), textFile: false);
        File.Copy(Application.ExecutablePath, Path.Combine(payload, "DeepSeek Harness 控制台.exe"), overwrite: true);
        return Path.Combine(SupportRoot, "Install-DeepSeekHarness.ps1");
    }

    private static void ExtractResource(string resourceName, string destination, bool textFile)
    {
        using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"缺少内置安装资源：{resourceName}");
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        if (textFile)
        {
            using var reader = new StreamReader(source, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            File.WriteAllText(destination, reader.ReadToEnd(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
            return;
        }
        using var output = File.Create(destination);
        source.CopyTo(output);
    }

    private async Task StopResidualHarnessProcessesAsync()
    {
        var scriptPath = Path.Combine(SupportRoot, "Stop-Residual-Harness.ps1");
        const string script = """
$ErrorActionPreference = 'Stop'
$profilePath = [regex]::Escape((Join-Path $env:USERPROFILE '.dsh\profiles'))
$matches = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -match '@deepseek-ai[\\/]dsh[\\/]lib[\\/]bin\.js' -and
    $_.CommandLine -match '\bweb\b' -and
    $_.CommandLine -match $profilePath
})
foreach ($match in $matches) {
    Stop-Process -Id $match.ProcessId -Force -ErrorAction Stop
    Write-Output "已结束残留 Harness 进程：$($match.ProcessId)"
}
if ($matches.Count -eq 0) { Write-Output '未发现残留 Harness 进程。' }
""";
        Directory.CreateDirectory(SupportRoot);
        File.WriteAllText(scriptPath, script, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
        Append("正在检查残留 Harness 进程…");
        await ExecutePowerShellAsync(scriptPath, string.Empty, "关闭");
    }

    private async Task DeleteDirectoryWithRetryAsync(string target)
    {
        Exception? lastError = null;
        ClearReadOnlyAttributes(target);
        for (var attempt = 1; attempt <= 8; attempt++)
        {
            try
            {
                await Task.Run(() => Directory.Delete(target, recursive: true));
                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                lastError = ex;
                if (attempt == 8) break;
                Append($"目录仍被占用，{attempt} 秒后重试（{attempt}/8）：{Path.GetFileName(target)}");
                await Task.Delay(TimeSpan.FromSeconds(1));
            }
        }
        throw lastError ?? new IOException($"无法删除目录：{target}");
    }

    private static void ClearReadOnlyAttributes(string target)
    {
        var pending = new Stack<string>();
        pending.Push(target);
        while (pending.Count > 0)
        {
            var current = pending.Pop();
            try
            {
                var attributes = File.GetAttributes(current);
                if ((attributes & FileAttributes.ReparsePoint) != 0) continue;
                if ((attributes & FileAttributes.ReadOnly) != 0)
                    File.SetAttributes(current, attributes & ~FileAttributes.ReadOnly);

                if (!Directory.Exists(current)) continue;
                foreach (var child in Directory.EnumerateFileSystemEntries(current))
                    pending.Push(child);
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }

    private static void WriteUninstallReport(IEnumerable<string> removed, IEnumerable<string> failures)
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "DeepSeek Harness 卸载报告.txt");
        var lines = new List<string>
        {
            "DeepSeek Harness 卸载结果报告",
            $"生成时间：{DateTime.Now:yyyy-MM-dd HH:mm:ss}",
            "服务地址：http://127.0.0.1:3080/",
            "--- 已删除 ---",
        };
        lines.AddRange(removed.DefaultIfEmpty("未发现可删除的 Harness 数据。"));
        lines.Add("--- 失败项目 ---");
        lines.AddRange(failures.DefaultIfEmpty("无"));
        File.WriteAllLines(path, lines, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
    }

    private async Task RefreshStatusAsync()
    {
        if (_stopInProgress)
        {
            ApplyUiState(OperationUiState.ForStopping());
            return;
        }
        if (_activeAction is not null)
        {
            ApplyUiState(OperationUiState.ForActivity(_activeAction, _activeAllowStop, _stopInProgress));
            return;
        }
        var status = await GetHarnessHttpStatusAsync();
        ApplyUiState(OperationUiState.ForIdle(GetInstallationCondition(), status));
    }

    private async Task RefreshStatusSafelyAsync()
    {
        try
        {
            await RefreshStatusAsync();
        }
        catch (Exception ex)
        {
            ApplyUiState(OperationUiState.ForIdle(GetInstallationCondition(), httpStatus: 0));
            Append($"刷新状态失败，已恢复操作按钮：{ex.Message}");
        }
    }

    private static async Task<int> GetHarnessHttpStatusAsync()
    {
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
            using var response = await client.GetAsync(HarnessUrl);
            return (int)response.StatusCode;
        }
        catch
        {
            return 0;
        }
    }

    private void BeginOperation(string action, bool allowStop)
    {
        _activeAction = action;
        _activeAllowStop = allowStop;
        _activeCancellation = new CancellationTokenSource();
        ApplyUiState(OperationUiState.ForRunning(action, allowStop));
    }

    private void EndOperation()
    {
        _activeAction = null;
        _activeAllowStop = false;
        _activeCancellation?.Dispose();
        _activeCancellation = null;
        if (_stopInProgress)
        {
            ApplyUiState(OperationUiState.ForStopping());
            return;
        }

        ApplyUiState(OperationUiState.ForIdle(GetInstallationCondition(), httpStatus: 0));
    }

    private void SetStoppingUi()
    {
        ApplyUiState(OperationUiState.ForStopping());
    }

    private void ApplyUiState(OperationUiState state)
    {
        _install.Enabled = state.Install;
        _start.Enabled = state.Start;
        _stop.Enabled = state.Stop;
        _update.Enabled = state.Update;
        _uninstall.Enabled = state.Uninstall;
        _status.Text = state.Status;
        _hint.Text = state.Hint;
    }

    private static InstallationCondition GetInstallationCondition() =>
        InstallationConditionDetector.Detect(HarnessRoot, ProfileRoot, LocalPluginRoot);

    private static string ResolvePowerShell()
    {
        var powerShell7 = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        if (!File.Exists(powerShell7))
        {
            throw new InvalidOperationException("未找到 PowerShell 7，请先安装 PowerShell 7（pwsh.exe）。");
        }
        return powerShell7;
    }

    private void Append(string text)
    {
        if (IsDisposed) return;
        if (InvokeRequired)
        {
            BeginInvoke(() => Append(text));
            return;
        }
        var clean = Regex.Replace(text, "\\x1B\\[[0-?]*[ -/]*[@-~]", string.Empty).Trim();
        if (string.IsNullOrEmpty(clean)) return;
        _log.AppendText($"[{DateTime.Now:HH:mm:ss}] {clean}{Environment.NewLine}");
        _log.SelectionStart = _log.TextLength;
        _log.ScrollToCaret();
    }
}
