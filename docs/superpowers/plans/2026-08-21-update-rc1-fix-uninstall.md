# DeepSeek Harness rc.1 更新与卸载修复实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:verification-before-completion 在提交和推送前重新验证。

**目标：** 将安装器的 Harness 初始版本同步到官方 `0.1.1-rc.1`，并修复卸载遇到只读文件时失败的问题。

**架构：** 保留更新脚本按已发布版本动态发现正式版和 RC 版的逻辑，仅调整新安装的初始版本。卸载删除目录前递归清除文件和目录的只读属性，再使用现有重试机制删除；不扩大卸载目标范围。

**技术栈：** C# .NET 10 Windows Forms、PowerShell 7、Git。

---

### 任务 1：修复卸载只读文件失败

**文件：**
- 修改：`HarnessControl/Program.cs` 的 `DeleteDirectoryWithRetryAsync`

- [x] 用只读临时文件复现 `Directory.Delete(..., recursive:true)` 的 `UnauthorizedAccessException`。
- [x] 在删除前递归将目标目录内的文件和目录属性设为 `Normal`，再执行现有删除重试。
- [x] 用同样的只读临时目录验证修复路径可删除，并确认仓库构建通过。

### 任务 2：同步官方 Harness 初始版本

**文件：**
- 修改：`Installer/Install-DeepSeekHarness.ps1`
- 修改：`README.md`

- [x] 将新安装基线从 `0.1.0-rc.7` 更新为 `0.1.1-rc.1`。
- [x] 保持更新器动态读取 npm 已发布版本的行为，并补充当前基线说明。

### 任务 3：合并验证与交付

**文件：**
- 修改：上述实现文件及本计划文件

- [x] 使用仓库内 .NET SDK 执行 Release 构建。
- [x] 确认 `git diff --check`、工作区状态和远端基线。
- [ ] 提交变更并推送 `main`。
- [ ] 推送后重新确认本地 `main` 与 `origin/main` 同步。
