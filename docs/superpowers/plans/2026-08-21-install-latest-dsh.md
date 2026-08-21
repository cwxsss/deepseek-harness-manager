# 动态安装最新 DSH 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 让新安装在运行时解析并安装 npm 上最高的官方 `@deepseek-ai/dsh` 正式版或 `rc.N` 版本，不再固定为 `0.1.1-rc.1`。

**架构：** 在启动器目录新增一个可独立测试的版本选择脚本，纯选择函数处理版本排序，查询函数通过 Corepack/pnpm 获取已发布版本。安装器和两份更新脚本共用该助手，管理器把它作为嵌入资源释放到运行时 payload。

**技术栈：** PowerShell 7、pnpm/Corepack、.NET 10 WinForms 单文件发布、Git。

---

## 文件结构

- 创建 `Installer/payload/launcher/Version.Common.ps1`：版本解析、排序与 npm 查询。
- 创建 `tests/Version.Common.Tests.ps1`：对真实版本选择函数执行行为测试。
- 修改 `tests/Verify-Installer.ps1`：运行版本测试，并验证安装器能解析且发布资源存在。
- 修改 `Installer/Install-DeepSeekHarness.ps1`：查询、记录并安装最高版本。
- 修改 `Installer/payload/launcher/Update-DeepSeekHarness.ps1`：删除内联选择器，使用共享助手。
- 修改 `HarnessControl/Update-DeepSeekHarness.ps1`：保持仓库内副本与运行时更新器一致。
- 修改 `HarnessControl/HarnessControl.csproj`：嵌入版本助手。
- 修改 `HarnessControl/Program.cs`：安装时释放版本助手。
- 修改 `README.md` 与 `Installer/说明.txt`：说明新安装动态选择最高已发布版本。

### 任务 1：共享版本选择器

**文件：**
- 创建：`Installer/payload/launcher/Version.Common.ps1`
- 创建：`tests/Version.Common.Tests.ps1`

- [ ] **步骤 1：编写失败的行为测试**

测试导入真实助手并使用字面量版本列表断言：

```powershell
. (Join-Path $repoRoot 'Installer\payload\launcher\Version.Common.ps1')

Assert-Equal '0.1.1-rc.1' (Select-LatestDshVersion @('0.1.0-rc.8', '0.1.1-rc.1')) 'higher base RC'
Assert-Equal '0.1.1' (Select-LatestDshVersion @('0.1.1-rc.9', '0.1.1')) 'stable over same-base RC'
Assert-Equal '0.1.1-rc.10' (Select-LatestDshVersion @('0.1.1-rc.9', '0.1.1-rc.10')) 'numeric RC order'
```

同时断言未知 prerelease 被忽略、没有支持版本时抛出明确异常。

- [ ] **步骤 2：运行测试验证失败**

运行：

```powershell
pwsh -NoProfile -File .\tests\Version.Common.Tests.ps1
```

预期：FAIL，原因是 `Version.Common.ps1` 或 `Select-LatestDshVersion` 尚不存在。

- [ ] **步骤 3：实现最少版本选择与查询函数**

创建：

```powershell
function Select-LatestDshVersion {
    param([string[]]$Versions)
    $parsed = foreach ($version in $Versions) {
        if ([string]$version -match '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-rc\.(?<pre>\d+))?$') {
            [pscustomobject]@{
                Text = [string]$version
                Major = [int]$Matches.major
                Minor = [int]$Matches.minor
                Patch = [int]$Matches.patch
                Stable = if ([string]::IsNullOrEmpty($Matches.pre)) { 1 } else { 0 }
                Pre = if ([string]::IsNullOrEmpty($Matches.pre)) { 0 } else { [int]$Matches.pre }
            }
        }
    }
    $latest = $parsed | Sort-Object @{ Expression = 'Major'; Descending = $true }, @{ Expression = 'Minor'; Descending = $true }, @{ Expression = 'Patch'; Descending = $true }, @{ Expression = 'Stable'; Descending = $true }, @{ Expression = 'Pre'; Descending = $true } | Select-Object -First 1
    if ($null -eq $latest) { throw '无法识别可用的 DSH 已发布版本。' }
    return $latest.Text
}

function Get-LatestPublishedPackageVersion {
    param([string]$CorepackPath, [string]$PackageName)
    $raw = & $CorepackPath pnpm --color never view $PackageName versions --json
    if ($LASTEXITCODE -ne 0 -or $null -eq $raw) { throw "无法读取 $PackageName 的已发布版本列表。" }
    try { $versions = @((($raw -join [Environment]::NewLine) | ConvertFrom-Json)) }
    catch { throw "无法解析 $PackageName 的已发布版本列表：$($_.Exception.Message)" }
    return Select-LatestDshVersion -Versions $versions
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`pwsh -NoProfile -File .\tests\Version.Common.Tests.ps1`

预期：所有版本选择行为通过。

- [ ] **步骤 5：提交共享助手与测试**

```powershell
git add -- Installer/payload/launcher/Version.Common.ps1 tests/Version.Common.Tests.ps1
git commit -m "Add shared DSH version resolver"
```

### 任务 2：接入安装器、更新器与单文件资源

**文件：**
- 修改：`Installer/Install-DeepSeekHarness.ps1`
- 修改：`Installer/payload/launcher/Update-DeepSeekHarness.ps1`
- 修改：`HarnessControl/Update-DeepSeekHarness.ps1`
- 修改：`HarnessControl/HarnessControl.csproj`
- 修改：`HarnessControl/Program.cs`
- 修改：`tests/Verify-Installer.ps1`

- [ ] **步骤 1：扩展失败的集成检查**

让 `Verify-Installer.ps1` 调用 `Version.Common.Tests.ps1`，并解析安装器/项目资源，要求安装器使用 `Get-LatestPublishedPackageVersion`、项目嵌入 `Version.Common.ps1`。先运行并看到失败，因为生产接线尚未完成。

- [ ] **步骤 2：安装器动态选择版本**

在 Corepack 就绪后执行：

```powershell
. (Join-Path $launcherPayload 'Version.Common.ps1')
$latestCore = Get-LatestPublishedPackageVersion -CorepackPath $corepack -PackageName '@deepseek-ai/dsh'
Write-InstallLog "准备安装 Harness 最新版本：$latestCore。"
& $corepack pnpm --dir $ProfileRoot add "@deepseek-ai/dsh@$latestCore" '@deepseek-ai/cordis-plugin-group@1.0.1'
```

删除固定的 `@deepseek-ai/dsh@0.1.1-rc.1`。

- [ ] **步骤 3：更新器改用共享助手**

两份更新脚本均加载 `Version.Common.ps1`，删除内联 `Get-LatestPublishedVersion`，改用：

```powershell
$latestCore = Get-LatestPublishedPackageVersion -CorepackPath $corepack -PackageName '@deepseek-ai/dsh'
```

- [ ] **步骤 4：嵌入并释放助手资源**

在 `HarnessControl.csproj` 添加：

```xml
<EmbeddedResource Include="..\Installer\payload\launcher\Version.Common.ps1" LogicalName="HarnessControl.Resources.Version.Common.ps1" />
```

在 `EnsureInstallerPayload()` 添加：

```csharp
ExtractResource("HarnessControl.Resources.Version.Common.ps1", Path.Combine(launcher, "Version.Common.ps1"), textFile: true);
```

- [ ] **步骤 5：运行全部脚本检查**

运行：`pwsh -NoProfile -File .\tests\Verify-Installer.ps1`

预期：版本行为、安装器语法、资源接线和既有回归检查全部通过。

- [ ] **步骤 6：提交运行时接入**

```powershell
git add -- Installer/Install-DeepSeekHarness.ps1 Installer/payload/launcher/Update-DeepSeekHarness.ps1 HarnessControl/Update-DeepSeekHarness.ps1 HarnessControl/HarnessControl.csproj HarnessControl/Program.cs tests/Verify-Installer.ps1
git commit -m "Install latest published DSH version"
```

### 任务 3：文档、发布与交付验证

**文件：**
- 修改：`README.md`
- 修改：`Installer/说明.txt`
- 生成但不提交：`D:\下载\DeepSeek Harness 控制台-latest.exe`

- [ ] **步骤 1：更新用户说明**

README 和中文说明明确写入：安装时查询 npm 已发布版本并选择最高正式版或 RC；查询失败时停止安装；更新按钮沿用同一规则。

- [ ] **步骤 2：运行完整验证**

```powershell
pwsh -NoProfile -File .\tests\Verify-Installer.ps1
dotnet publish .\HarnessControl\HarnessControl.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true
git diff --check
```

预期：测试通过、发布退出码 0、生成单一 EXE、无 diff 格式错误。

- [ ] **步骤 3：提交文档**

```powershell
git add -- README.md Installer/说明.txt
git commit -m "Document latest-version installation"
```

- [ ] **步骤 4：复制并校验 EXE**

将发布 EXE 复制为 `D:\下载\DeepSeek Harness 控制台-latest.exe`，计算 SHA256，并确认 PE 签名头为 `MZ`。

- [ ] **步骤 5：合并并推送**

在主工作区合并功能分支，运行最终测试，推送 `main`，确认 `main...origin/main` 无领先或落后提交。
