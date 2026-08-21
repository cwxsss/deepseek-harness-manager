# 管理器操作可靠完成实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 修复安装成功后管理器长期停留在“正在安装”的问题，并以可重复的 Windows 自动测试和真实 GUI 安装验证阻止同类回归发布。

**架构：** 把 PowerShell 子进程生命周期从 WinForms 窗口中抽离为可测试的 `PowerShellProcessRunner`，以直接 PowerShell 进程退出为完成信号，对异步输出仅做有界收尾。把操作阶段和按钮可用性抽离为 `OperationUiState`，由窗口统一渲染；安装结果提示改为可直接行为测试的 PowerShell 助手。所有本地与 CI 检查通过后，再用新 EXE 执行一次真实 GUI 安装闭环。

**技术栈：** .NET 10、Windows Forms、`System.Diagnostics.Process`、PowerShell 7、Windows UI Automation、GitHub Actions Windows runner。

---

## 文件结构

- 创建 `Installer/Install.Completion.ps1`：返回安装成功尾部的服务状态文案，供安装器和行为测试共同调用。
- 创建 `Installer/Install.Target.ps1`：仅允许覆盖产品元数据匹配的旧桌面管理器，保护无关同名文件。
- 修改 `Installer/Install-DeepSeekHarness.ps1`：加载完成文案助手，替换错误的内联 `if`。
- 修改 `HarnessControl/HarnessControl.csproj`：编译新增 C# 文件并嵌入安装完成助手。
- 修改 `HarnessControl/Program.cs`：调用独立进程执行器、渲染统一操作状态、释放新增嵌入资源。
- 创建 `HarnessControl/PowerShellProcessRunner.cs`：启动 PowerShell、实时转发输出、以直接进程退出为准、有界结束输出读取、处理取消和超时。
- 创建 `HarnessControl/OperationUiState.cs`：定义操作阶段和按钮可用性映射。
- 创建 `HarnessControl/InstallationCondition.cs`：区分未安装、残缺安装和完整安装，防止残缺安装丢失修复入口。
- 创建 `HarnessControl/OperationExecutionCoordinator.cs`：保证成功、失败、异常、超时和取消均执行一次最终收尾。
- 创建 `HarnessControl/OperationStopCoordinator.cs`：让取消后的关闭等待原操作释放同一个 gate。
- 创建 `HarnessControl/Properties/AssemblyInfo.cs`：向测试程序集开放内部类型。
- 创建 `HarnessControl.Tests/HarnessControl.Tests.csproj`：不依赖第三方测试包的 Windows 控制台测试项目。
- 创建 `HarnessControl.Tests/Program.cs`：运行进程生命周期和按钮状态行为测试。
- 创建 `tests/fixtures/RetainedOutputHandle.ps1`：父 PowerShell 退出后让后台子进程继续持有输出句柄。
- 创建 `tests/fixtures/ExitWithCode.ps1`：输出日志后返回指定非零退出码。
- 创建 `tests/fixtures/WaitUntilCancelled.ps1`：供取消和超时测试使用。
- 创建 `tests/Install.Completion.Tests.ps1`：执行安装尾部的两个真实生产分支。
- 创建 `tests/Install.Target.Tests.ps1`：验证旧管理器可安全替换、无关同名文件会被拒绝。
- 修改 `tests/Verify-Installer.ps1`：接入安装完成行为测试并验证嵌入/释放接线。
- 创建 `tests/Run-All.ps1`：本地和 CI 共用的脚本测试、.NET 测试、构建、发布及单 EXE 形态门禁。
- 创建 `tests/Verify-RealInstall.ps1`：显式确认后启动新 EXE，通过 UI Automation 完成一次真实安装并断言状态与按钮。
- 创建 `.github/workflows/windows-tests.yml`：PR 和 `main` 推送的 Windows 自动门禁。
- 修改 `README.md`：记录测试、真实安装门禁以及“测试未通过不得发布”的规则。

### 任务 1：让安装完成尾部可执行、可回归测试

**文件：**
- 创建：`Installer/Install.Completion.ps1`
- 创建：`tests/Install.Completion.Tests.ps1`
- 修改：`Installer/Install-DeepSeekHarness.ps1:1-10,185-191`
- 修改：`HarnessControl/HarnessControl.csproj`
- 修改：`HarnessControl/Program.cs:440-460`
- 修改：`tests/Verify-Installer.ps1`

- [ ] **步骤 1：先编写失败的生产行为测试**

`tests/Install.Completion.Tests.ps1` 必须导入尚不存在的真实助手，并验证两个分支：

```powershell
$ErrorActionPreference = 'Stop'
$helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'Installer\Install.Completion.ps1'
. $helper

$notStarted = Get-InstallServiceCompletionMessage -NoLaunch $true
$healthy = Get-InstallServiceCompletionMessage -NoLaunch $false

if ($notStarted -ne '服务未启动（安装参数指定 NoLaunch）。') { throw "NoLaunch 文案错误：$notStarted" }
if ($healthy -ne '服务健康检查通过（HTTP 200）。') { throw "健康文案错误：$healthy" }
Write-Output 'Install completion behavior tests passed (2 checks).'
```

- [ ] **步骤 2：运行红灯并确认失败原因正确**

运行：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File .\tests\Install.Completion.Tests.ps1
```

预期：FAIL，因为 `Installer/Install.Completion.ps1` 尚不存在；不得以语法错误、路径拼写错误或测试自身错误作为合格红灯。

- [ ] **步骤 3：添加最小生产助手并接入安装器**

`Installer/Install.Completion.ps1`：

```powershell
function Get-InstallServiceCompletionMessage {
    param([Parameter(Mandatory = $true)][bool]$NoLaunch)
    if ($NoLaunch) { return '服务未启动（安装参数指定 NoLaunch）。' }
    return '服务健康检查通过（HTTP 200）。'
}
```

在安装器开头通过 `$PSScriptRoot` dot-source 助手，并把错误语句替换为：

```powershell
Write-InstallLog (Get-InstallServiceCompletionMessage -NoLaunch ([bool]$NoLaunch))
```

把助手作为 `HarnessControl.Resources.Install.Completion.ps1` 嵌入单 EXE，并在 `EnsureInstallerPayload` 中释放到安装脚本同目录。

- [ ] **步骤 4：扩展安装器接线检查并验证绿灯**

`tests/Verify-Installer.ps1` 先运行 `Install.Completion.Tests.ps1`，再断言：安装器调用 `Get-InstallServiceCompletionMessage`、不存在 `Write-InstallLog (if`、项目包含嵌入资源、管理器释放该资源。

运行：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File .\tests\Install.Completion.Tests.ps1
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File .\tests\Verify-Installer.ps1
```

预期：两项均 PASS，并实际返回两个准确的中文完成文案。

- [ ] **步骤 5：提交安装尾部修复**

```powershell
git add -- Installer/Install.Completion.ps1 Installer/Install-DeepSeekHarness.ps1 HarnessControl/HarnessControl.csproj HarnessControl/Program.cs tests/Install.Completion.Tests.ps1 tests/Verify-Installer.ps1
git commit -m "Fix installer completion reporting"
```

### 任务 2：以直接 PowerShell 进程退出结束操作

**文件：**
- 创建：`HarnessControl/PowerShellProcessRunner.cs`
- 创建：`HarnessControl/Properties/AssemblyInfo.cs`
- 创建：`HarnessControl.Tests/HarnessControl.Tests.csproj`
- 创建：`HarnessControl.Tests/Program.cs`
- 创建：`tests/fixtures/RetainedOutputHandle.ps1`
- 创建：`tests/fixtures/ExitWithCode.ps1`
- 创建：`tests/fixtures/WaitUntilCancelled.ps1`
- 修改：`HarnessControl/Program.cs:365-423`

- [ ] **步骤 1：编写保留输出句柄的失败测试**

`RetainedOutputHandle.ps1` 使用 `Start-Process pwsh.exe -NoNewWindow -PassThru` 启动睡眠 30 秒的后台子进程，把 PID 写入测试指定文件，输出一行后让父脚本立即退出 0。`HarnessControl.Tests` 直接调用生产 `PowerShellProcessRunner`，断言：

```csharp
var result = await runner.RunAsync(fixture, args, "安装", TimeSpan.FromSeconds(10), CancellationToken.None);
Assert(result.ExitCode == 0, "父 PowerShell 的退出码应为 0");
Assert(stopwatch.Elapsed < TimeSpan.FromSeconds(5), "后台子进程持有输出句柄时执行器仍须在五秒内返回");
Assert(Process.GetProcessById(childPid).HasExited == false, "执行器不得误杀已分离的服务子进程");
```

测试的 `finally` 只精确结束 PID 文件记录的测试子进程并删除测试临时目录。

- [ ] **步骤 2：运行红灯并确认复现当前卡死**

运行：

```powershell
dotnet run --project .\HarnessControl.Tests\HarnessControl.Tests.csproj -- retained-output
```

预期：FAIL；当前没有独立执行器，或当前等待策略超过五秒。测试必须证明失败来自父进程退出后仍等待输出 EOF。

- [ ] **步骤 3：实现最小进程执行器**

生产接口固定为：

```csharp
internal sealed record PowerShellProcessResult(int ExitCode, ProcessCompletionReason Reason);
internal enum ProcessCompletionReason { Exited, Cancelled, TimedOut }

internal sealed class PowerShellProcessRunner
{
    public PowerShellProcessRunner(string powerShellPath, Action<string> append);
    public Task<PowerShellProcessResult> RunAsync(
        string scriptPath,
        string arguments,
        string action,
        TimeSpan timeout,
        CancellationToken cancellationToken);
}
```

实现要求：

1. 保持 `UseShellExecute=false` 和标准输出/错误重定向。
2. 为 `Exited` 事件建立 `TaskCompletionSource<int>`，以直接 PowerShell 进程退出作为主完成任务，不调用会等待异步输出 EOF 的 `WaitForExitAsync`。
3. 输出和错误事件继续调用 `append`；收到空数据时分别完成输出 EOF 任务。
4. 主进程退出后最多等待 500 毫秒输出 EOF，然后调用 `CancelOutputRead`/`CancelErrorRead`、解绑事件并返回已读取的退出码。
5. 超时返回 `TimedOut`，用户令牌取消返回 `Cancelled`；二者精确结束直接操作进程树。
6. 普通 `Exited` 不结束后台 Harness 服务。

- [ ] **步骤 4：让保留句柄测试转绿**

运行：

```powershell
dotnet run --project .\HarnessControl.Tests\HarnessControl.Tests.csproj -- retained-output
```

预期：PASS；父进程退出后五秒内返回，后台测试子进程仍存活，最后由测试清理。

- [ ] **步骤 5：先添加非零退出、取消和超时行为测试**

在 `HarnessControl.Tests/Program.cs` 增加真实脚本断言：

```csharp
Assert((await RunExitCodeFixture(23)).ExitCode == 23, "必须传播非零退出码");
Assert((await RunCancellationFixture()).Reason == ProcessCompletionReason.Cancelled, "必须区分用户取消");
Assert((await RunTimeoutFixture()).Reason == ProcessCompletionReason.TimedOut, "必须区分十五分钟操作超时的通用机制");
```

先临时让执行器只支持正常退出，运行指定用例并确认取消、超时测试失败，再添加最小的令牌与超时竞争逻辑使其通过。

- [ ] **步骤 6：把 `MainForm` 接入生产执行器**

`ExecutePowerShellAsync` 调用 `PowerShellProcessRunner.RunAsync`，把 `Exited` 的退出码传给现有日志分支；`Cancelled` 和 `TimedOut` 分别生成当前中文取消/超时日志。保留启动 HTTP 200 快速完成行为，但它只结束启动器 PowerShell，不结束 Node 服务。

- [ ] **步骤 7：运行全部进程生命周期测试和 Release 构建**

运行：

```powershell
dotnet run --project .\HarnessControl.Tests\HarnessControl.Tests.csproj
dotnet build .\HarnessControl\HarnessControl.csproj -c Release
```

预期：所有进程用例 PASS；构建退出码 0、零错误。

- [ ] **步骤 8：提交进程生命周期修复**

```powershell
git add -- HarnessControl/PowerShellProcessRunner.cs HarnessControl/Properties/AssemblyInfo.cs HarnessControl/HarnessControl.csproj HarnessControl/Program.cs HarnessControl.Tests tests/fixtures/RetainedOutputHandle.ps1 tests/fixtures/ExitWithCode.ps1 tests/fixtures/WaitUntilCancelled.ps1
git commit -m "Finish manager operations when PowerShell exits"
```

### 任务 3：让每种结果都恢复正确按钮状态

**文件：**
- 创建：`HarnessControl/OperationUiState.cs`
- 修改：`HarnessControl/Program.cs:312-348,590-640`
- 修改：`HarnessControl.Tests/Program.cs`

- [ ] **步骤 1：编写按钮状态红灯测试**

定义测试期望 API：

```csharp
var running = OperationUiState.ForRunning(allowStop: true);
Assert(!running.Install && !running.Start && running.Stop && !running.Update && !running.Uninstall, "运行安装时只能关闭");

foreach (var outcome in new[] { "success", "failure", "exception", "timeout", "cancelled" })
{
    var idle = OperationUiState.ForIdle(InstallationCondition.Complete, httpStatus: 200);
    Assert(idle.Install && !idle.Start && idle.Stop && idle.Update && idle.Uninstall,
        $"{outcome} 收尾后运行中的 Harness 必须允许重新安装、关闭、更新和卸载");
}
```

另测 `ForIdle(InstallationCondition.None, 0)` 只启用安装；`Incomplete` 启用修复安装和卸载；`Complete, 0` 启用重新安装、启动、更新和卸载。取消后关闭用例必须断言 Stopping 优先且关闭操作等待原操作 gate。

- [ ] **步骤 2：运行红灯**

运行：

```powershell
dotnet run --project .\HarnessControl.Tests\HarnessControl.Tests.csproj -- ui-state
```

预期：FAIL，因为 `OperationUiState` 尚不存在。

- [ ] **步骤 3：实现状态模型并统一渲染**

实现不可变状态：

```csharp
internal sealed record OperationUiState(
    bool Install, bool Start, bool Stop, bool Update, bool Uninstall,
    string Status, string Hint);
```

提供 `ForRunning(bool allowStop)`、`ForStopping()`、`ForActivity(...)`、`ForIdle(InstallationCondition, int httpStatus)`。`MainForm` 新增唯一 `ApplyUiState(OperationUiState state)` 设置五个按钮、状态和提示；`BeginOperation`、`SetStoppingUi`、`EndOperation/RefreshStatusAsync` 不再各自散落设置控件。`OperationExecutionCoordinator` 统一最终收尾，`OperationStopCoordinator` 串行化取消后的关闭。

- [ ] **步骤 4：保证异常刷新也释放操作锁**

保持 `RunExclusiveAsync` 的最外层 `finally`，先清理 `_activeAction`、取消源和进程引用，再尝试 HTTP 状态刷新；即使刷新抛出异常，也应用一个基于安装目录的非忙碌回退状态并释放 `_operationGate`。

- [ ] **步骤 5：运行状态、生命周期和安装器测试**

运行：

```powershell
dotnet run --project .\HarnessControl.Tests\HarnessControl.Tests.csproj
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File .\tests\Verify-Installer.ps1
```

预期：全部 PASS；测试日志分别列出成功、失败、异常、超时、取消的 idle-state 断言。

- [ ] **步骤 6：提交按钮状态修复**

```powershell
git add -- HarnessControl/OperationUiState.cs HarnessControl/Program.cs HarnessControl.Tests/Program.cs
git commit -m "Restore manager controls after every operation"
```

### 任务 4：建立本地与 GitHub Actions 发布门禁

**文件：**
- 创建：`tests/Run-All.ps1`
- 创建：`.github/workflows/windows-tests.yml`
- 修改：`README.md`

- [ ] **步骤 1：编写统一本地门禁脚本**

`tests/Run-All.ps1` 设置 `$ErrorActionPreference='Stop'` 并依次执行：

```powershell
& (Join-Path $PSScriptRoot 'Verify-Installer.ps1')
dotnet run --project (Join-Path $repoRoot 'HarnessControl.Tests\HarnessControl.Tests.csproj') -c Release
if ($LASTEXITCODE -ne 0) { throw "管理器行为测试失败：$LASTEXITCODE" }
dotnet build (Join-Path $repoRoot 'HarnessControl\HarnessControl.csproj') -c Release
if ($LASTEXITCODE -ne 0) { throw "Release 构建失败：$LASTEXITCODE" }
dotnet publish (Join-Path $repoRoot 'HarnessControl\HarnessControl.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true
if ($LASTEXITCODE -ne 0) { throw "单文件发布失败：$LASTEXITCODE" }
```

随后检查 publish 目录恰好有一个交付 EXE、文件头为 `MZ`，且 `.pdb`、`.dll`、安装脚本或 payload 不属于交付清单。

- [ ] **步骤 2：先运行统一门禁并修正脚本自身问题**

运行：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File .\tests\Run-All.ps1
```

预期：所有既有测试、新行为测试、构建与单 EXE 检查 PASS；任何一步失败都让脚本非零退出。

- [ ] **步骤 3：创建 GitHub Actions Windows 工作流**

`.github/workflows/windows-tests.yml` 固定：

```yaml
name: Windows tests
on:
  pull_request:
  push:
    branches: [main]
jobs:
  test:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: 10.0.x
      - name: Run release gates
        shell: pwsh
        run: ./tests/Run-All.ps1
```

- [ ] **步骤 4：更新维护说明**

README 明确写入：本地必须运行 `tests/Run-All.ps1`；PR/`main` 必须等待 `Windows tests` 通过；真实安装验证失败时禁止复制或发布 EXE。

- [ ] **步骤 5：验证 YAML、门禁和工作树**

运行：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File .\tests\Run-All.ps1
git diff --check
git status --short
```

预期：门禁 PASS、无空白错误、状态只包含本任务文件。

- [ ] **步骤 6：提交发布门禁**

```powershell
git add -- tests/Run-All.ps1 .github/workflows/windows-tests.yml README.md
git commit -m "Gate releases on Windows regression tests"
```

### 任务 5：自动化真实 GUI 安装闭环并发布

**文件：**
- 创建：`tests/Verify-RealInstall.ps1`
- 修改：`README.md`

- [ ] **步骤 1：编写带明确安全开关的 GUI 验证脚本**

脚本必须要求：

```powershell
param(
    [Parameter(Mandatory = $true)][string]$ManagerExe,
    [switch]$ConfirmRealInstall
)
if (-not $ConfirmRealInstall) { throw '必须显式传入 -ConfirmRealInstall；该测试会停止并替换当前 DSH 安装。' }
```

它验证 EXE 绝对路径、启动管理器、使用 `System.Windows.Automation` 查找并 Invoke“安装 DeepSeek”，对现有安装确认框选择“是”，轮询最长 15 分钟。成功条件必须同时满足：

1. 状态文本不含 `正在安装`；
2. 日志包含 `安装完成`；
3. `http://127.0.0.1:3080/` 返回 200；
4. “关闭 DeepSeek”和“更新 DeepSeek”均 `IsEnabled=true`；
5. 已安装 `@deepseek-ai/dsh/package.json` 的版本等于共享版本解析器当前选出的最高已发布稳定版或 `rc.N`。

脚本只关闭管理器窗口，不停止健康的 DSH 服务；失败时保留桌面安装报告和 Harness 日志并以非零退出。

- [ ] **步骤 2：将真实安装列入 README 发布流程**

记录精确命令：

```powershell
$managerExe = (Resolve-Path -LiteralPath '.\HarnessControl\bin\Release\net10.0-windows\win-x64\publish\DeepSeek Harness 控制台.exe').Path
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File .\tests\Verify-RealInstall.ps1 -ManagerExe $managerExe -ConfirmRealInstall
```

明确该脚本不在共享 GitHub runner 上执行，因为它会替换真实用户安装；它是发布人员本机的第二道强制门禁。

- [ ] **步骤 3：提交真实 GUI 验证工具**

```powershell
git add -- tests/Verify-RealInstall.ps1 README.md
git commit -m "Automate real manager installation verification"
```

- [ ] **步骤 4：运行所有本地自动门禁并生成候选 EXE**

运行：

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File .\tests\Run-All.ps1
```

预期：脚本、生命周期、状态、构建、发布和单 EXE 形态全部 PASS。

- [ ] **步骤 5：用候选 EXE 执行真实 GUI 安装验证**

在用户已确认本计划会替换当前测试安装的授权范围内，运行 `Verify-RealInstall.ps1 -ConfirmRealInstall`。预期：15 分钟内输出 DSH 版本、HTTP 200、非忙碌状态，以及关闭/更新按钮均可用。

- [ ] **步骤 6：复制唯一交付物并计算校验值**

仅把 publish 目录中的 `DeepSeek Harness 控制台.exe` 复制为：

```text
D:\下载\DeepSeek Harness 控制台-latest.exe
```

计算 SHA256，检查 `MZ` 文件头，并确认下载目录不需要附带 payload、`.pdb` 或脚本。

- [ ] **步骤 7：推送功能分支、创建 PR 并验证远端门禁**

推送功能分支并创建 Pull Request，等待 `Windows tests` 成功后合并，再让本地 `main` 快进到远端合并结果。最终核对：

```powershell
git push -u origin feature/manager-operation-completion
$prNumber = gh pr view feature/manager-operation-completion --json number --jq '.number'
gh pr checks $prNumber --watch
gh pr merge $prNumber --merge --delete-branch
git switch main
git pull --ff-only origin main
git ls-remote origin refs/heads/main
git status --short --branch
```

预期：GitHub `Windows tests` 成功；PR 已合并；本地和远端 `main` 指向相同提交；工作树干净。任何门禁失败都停止合并和发布。
