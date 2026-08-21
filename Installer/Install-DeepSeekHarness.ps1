param(
    [switch]$NoLaunch,
    [switch]$Repair,
    [string]$HarnessRoot = (Join-Path $env:LOCALAPPDATA 'DeepSeekHarness'),
    [string]$ProfileRoot = (Join-Path $env:USERPROFILE '.dsh\profiles'),
    [string]$DesktopPath = ([Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory))
)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$packageRoot = Split-Path -Parent $PSCommandPath
$payloadRoot = Join-Path $packageRoot 'payload'
$localPluginRoot = Join-Path (Split-Path -Parent $ProfileRoot) 'local-plugins\packages'
$desktopController = Join-Path $DesktopPath 'DeepSeek Harness 控制台.exe'
$reportPath = Join-Path $DesktopPath 'DeepSeek Harness 安装报告.txt'
$reportLines = [System.Collections.Generic.List[string]]::new()

function Write-InstallLog {
    param([string]$Message)
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    $reportLines.Add($line)
    Write-Host $line
}
function Save-InstallReport {
    $header = @(
        'DeepSeek Harness 安装结果报告',
        ('生成时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('服务地址：http://127.0.0.1:3080/'),
        ('Harness 安装目录：' + $HarnessRoot),
        ('配置目录：' + $ProfileRoot),
        '--- 安装日志 ---'
    )
    Set-Content -LiteralPath $reportPath -Value ($header + $reportLines) -Encoding utf8
}
function Require-Payload { param([string]$Path) if (-not (Test-Path -LiteralPath $Path)) { throw "安装包不完整，缺少：$Path" } }

if ($Repair) {
    Require-Payload (Join-Path $payloadRoot 'launcher')
    if (-not (Test-Path -LiteralPath $HarnessRoot) -or -not (Test-Path -LiteralPath $ProfileRoot)) { throw '未找到可修复的 DeepSeek Harness 安装。' }
    try {
        Write-InstallLog '开始修复启动器脚本编码。'
        $launcherPayload = Join-Path $payloadRoot 'launcher'
        $launcherRoot = Join-Path $HarnessRoot 'deepseek-harness-launcher'
        New-Item -ItemType Directory -Path $launcherRoot -Force | Out-Null
        Get-ChildItem -LiteralPath $launcherPayload -Force | Copy-Item -Destination $launcherRoot -Recurse -Force
        $commonPath = Join-Path $launcherRoot 'Launcher.Common.ps1'
        $commonContent = (Get-Content -LiteralPath $commonPath -Raw).Replace('C:\Users\chuai\AppData\Local\DeepSeekHarness', $HarnessRoot)
        [System.IO.File]::WriteAllText($commonPath, $commonContent, [System.Text.UTF8Encoding]::new($true))
        $legacyEntries = @(
            (Join-Path $DesktopPath '启动 DeepSeek Harness.vbs'),
            (Join-Path $DesktopPath '关闭 DeepSeek Harness.vbs')
        )
        $removedEntries = @($legacyEntries | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        if ($removedEntries.Count -gt 0) {
            Remove-Item -LiteralPath $removedEntries -Force
            Write-InstallLog ("已移除历史桌面入口：" + ($removedEntries -join '、'))
        }
        else {
            Write-InstallLog '未发现历史 VBS 桌面入口。'
        }
        Write-InstallLog '重新启动服务并执行健康检查。'
        $startOutput = & (Join-Path $launcherRoot 'Start-DeepSeekHarness.ps1') -PassThru 2>&1
        $startOutput | ForEach-Object { Write-InstallLog ("启动日志：" + $_.ToString()) }
        if ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 'http://127.0.0.1:3080/').StatusCode -ne 200) { throw '修复后的服务健康检查失败。' }
        Write-InstallLog '修复完成，服务健康检查通过（HTTP 200）。'
        Save-InstallReport
        return
    }
    catch {
        Write-InstallLog "修复失败：$($_.Exception.Message)"
        Save-InstallReport
        Write-Error "修复未完成：$($_.Exception.Message)。安装报告：$reportPath"
        exit 1
    }
}

Require-Payload (Join-Path $payloadRoot 'DeepSeek Harness 控制台.exe')
Require-Payload (Join-Path $payloadRoot 'launcher')
Require-Payload (Join-Path $payloadRoot 'launcher\Version.Common.ps1')
Require-Payload (Join-Path $payloadRoot 'plugins\sss-dsh-billing-0.1.5.tgz')
Require-Payload (Join-Path $payloadRoot 'plugins\sss-dsh-codex-reasoning-0.1.2.tgz')
$nodeVersion = 'node-v22.17.1-win-x64'
$nodeRuntimeRoot = Join-Path $HarnessRoot 'node-runtime'
$nodeRoot = Join-Path $nodeRuntimeRoot $nodeVersion
$nodeExecutable = Join-Path $nodeRoot 'node.exe'
$legacyNodeRoot = Join-Path $HarnessRoot $nodeVersion
$legacyNodeExecutable = Join-Path $legacyNodeRoot 'node.exe'
$hasLegacyNodeRuntime = (Test-Path -LiteralPath $legacyNodeExecutable -PathType Leaf) -and -not (Test-Path -LiteralPath $nodeExecutable -PathType Leaf)
if ($hasLegacyNodeRuntime) {
    Write-InstallLog '发现上次安装留下的 Node 运行环境，正在迁移到标准目录。'
    New-Item -ItemType Directory -Path $nodeRuntimeRoot -Force | Out-Null
    Move-Item -LiteralPath $legacyNodeRoot -Destination $nodeRuntimeRoot -Force
}
$existingWebManifest = Join-Path $ProfileRoot 'web\package.json'
$canResume = (Test-Path -LiteralPath $nodeExecutable) -and (Test-Path -LiteralPath (Join-Path $ProfileRoot 'package.json')) -and (-not (Test-Path -LiteralPath $existingWebManifest))
$hasPartialInstall = (Test-Path -LiteralPath $HarnessRoot) -and (Test-Path -LiteralPath $ProfileRoot) -and
    (-not (Test-Path -LiteralPath (Join-Path $ProfileRoot 'package.json'))) -and
    (-not (Test-Path -LiteralPath $existingWebManifest))
if ((Test-Path -LiteralPath $HarnessRoot) -or (Test-Path -LiteralPath $ProfileRoot)) {
    if (-not ($canResume -or $hasPartialInstall)) { throw "检测到已有 Harness 安装或配置。为保护现有内容，安装器不会覆盖它。" }
}
if ((Test-Path -LiteralPath $desktopController) -and (-not ($canResume -or $hasPartialInstall))) { throw "桌面已存在同名控制台：$desktopController。请先改名或移动该文件后重试。" }

try {
    if ($canResume) { Write-InstallLog '检测到上次核心安装未完成，正在从断点继续。' } else { Write-InstallLog '解压 Node 运行环境。' }
    New-Item -ItemType Directory -Path $HarnessRoot, $ProfileRoot, $localPluginRoot, $DesktopPath -Force | Out-Null
    if (-not (Test-Path -LiteralPath $nodeExecutable)) {
        $nodeArchive = Join-Path $payloadRoot 'node-runtime.tar'
        New-Item -ItemType Directory -Path $nodeRuntimeRoot -Force | Out-Null
        if (Test-Path -LiteralPath $nodeArchive -PathType Leaf) {
            & tar.exe -xf $nodeArchive -C $nodeRuntimeRoot
            if ($LASTEXITCODE -ne 0) { throw "Node 运行环境解压失败，退出码：$LASTEXITCODE" }
        }
        else {
            $nodeZip = Join-Path $packageRoot 'node-v22.17.1-win-x64.zip'
            Write-InstallLog '正在从 Node.js 官方下载运行环境（约 36 MB）。'
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri 'https://nodejs.org/download/release/v22.17.1/node-v22.17.1-win-x64.zip' -OutFile $nodeZip
            $extractRoot = Join-Path $HarnessRoot '.node-runtime-extract'
            if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
            New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
            try {
                Expand-Archive -LiteralPath $nodeZip -DestinationPath $extractRoot -Force
                $extractedNodeRoot = Join-Path $extractRoot $nodeVersion
                if (-not (Test-Path -LiteralPath (Join-Path $extractedNodeRoot 'node.exe') -PathType Leaf)) {
                    throw "压缩包内缺少 $nodeVersion\node.exe。"
                }
                Move-Item -LiteralPath $extractedNodeRoot -Destination $nodeRuntimeRoot -Force
            }
            catch {
                throw "Node 运行环境下载或解压失败：$($_.Exception.Message)。下载文件保留于：$nodeZip"
            }
            finally {
                if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue }
            }
            Remove-Item -LiteralPath $nodeZip -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $nodeExecutable -PathType Leaf)) { throw "Node 运行环境未就绪：$nodeExecutable" }
        }
    }
    $launcherPayload = Join-Path $payloadRoot 'launcher'
    $launcherRoot = Join-Path $HarnessRoot 'deepseek-harness-launcher'
    New-Item -ItemType Directory -Path $launcherRoot -Force | Out-Null
    Get-ChildItem -LiteralPath $launcherPayload -Force | Copy-Item -Destination $launcherRoot -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $payloadRoot 'plugins\sss-dsh-billing-0.1.5.tgz'), (Join-Path $payloadRoot 'plugins\sss-dsh-codex-reasoning-0.1.2.tgz') -Destination $localPluginRoot -Force

    Write-InstallLog '下载并安装官方 Harness、官方 Web UI 与两个本地 SSS 插件。'
    $corepack = Join-Path $HarnessRoot 'node-runtime\node-v22.17.1-win-x64\corepack.cmd'
    . (Join-Path $launcherPayload 'Version.Common.ps1')
    $latestCore = Get-LatestPublishedPackageVersion -CorepackPath $corepack -PackageName '@deepseek-ai/dsh'
    Write-InstallLog "准备安装 Harness 最新版本：$latestCore。"
    $profileWorkspace = "packages:`n  - .`n`nnodeLinker: isolated`nautoInstallPeers: true`nallowBuilds:`n  '@deepseek-ai/dsh-subprocess-local': true`n  '@google/genai': true`n  koffi: true`n  node-pty: true`n  protobufjs: true"
    [System.IO.File]::WriteAllText((Join-Path $ProfileRoot 'pnpm-workspace.yaml'), $profileWorkspace, [System.Text.UTF8Encoding]::new($false))
    & $corepack pnpm --dir $ProfileRoot add "@deepseek-ai/dsh@$latestCore" '@deepseek-ai/cordis-plugin-group@1.0.1'
    if ($LASTEXITCODE -ne 0) { throw "Harness 核心安装失败，退出码：$LASTEXITCODE" }
    & $corepack pnpm --dir $ProfileRoot rebuild --pending
    if ($LASTEXITCODE -ne 0) { throw "Harness 必需组件构建失败，退出码：$LASTEXITCODE" }
    $webManifest = @{
        name = 'dsh-profile-web'; private = $true
        dependencies = @{
            'sss-dsh-billing' = 'file:' + (Join-Path $localPluginRoot 'sss-dsh-billing-0.1.5.tgz').Replace('\', '/')
            'sss-dsh-codex-reasoning' = 'file:' + (Join-Path $localPluginRoot 'sss-dsh-codex-reasoning-0.1.2.tgz').Replace('\', '/')
        }
        dsh = @{ profile = @{ bundles = @('@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', 'sss-dsh-billing', 'sss-dsh-codex-reasoning') } }
    }
    $webRoot = Join-Path $ProfileRoot 'web'
    New-Item -ItemType Directory -Path $webRoot -Force | Out-Null
    $webManifestJson = $webManifest | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText((Join-Path $webRoot 'package.json'), $webManifestJson, [System.Text.UTF8Encoding]::new($false))
    $webWorkspace = "packages:`n  - .`n`nnodeLinker: isolated`nautoInstallPeers: true`nallowBuilds:`n  node-pty: true"
    [System.IO.File]::WriteAllText((Join-Path $webRoot 'pnpm-workspace.yaml'), $webWorkspace, [System.Text.UTF8Encoding]::new($false))
    & $corepack pnpm --dir $webRoot install
    if ($LASTEXITCODE -ne 0) { throw "Web UI 与插件安装失败，退出码：$LASTEXITCODE" }

    Write-InstallLog '创建桌面控制台。'
    $commonPath = Join-Path $HarnessRoot 'deepseek-harness-launcher\Launcher.Common.ps1'
    $commonContent = (Get-Content -LiteralPath $commonPath -Raw).Replace('C:\Users\chuai\AppData\Local\DeepSeekHarness', $HarnessRoot)
    [System.IO.File]::WriteAllText($commonPath, $commonContent, [System.Text.UTF8Encoding]::new($true))
    Copy-Item -LiteralPath (Join-Path $payloadRoot 'DeepSeek Harness 控制台.exe') -Destination $desktopController -Force
    if (-not $NoLaunch) {
        Write-InstallLog '首次启动并验证本机服务（首次加载插件最长可能需要 120 秒）。'
        & (Join-Path $launcherRoot 'Start-DeepSeekHarness.ps1') -PassThru 2>&1 | ForEach-Object { Write-InstallLog ("启动日志：" + $_.ToString()) }
        if ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 'http://127.0.0.1:3080/').StatusCode -ne 200) { throw '服务健康检查失败。' }
    }
    $coreVersion = (Get-Content -LiteralPath (Join-Path $ProfileRoot 'node_modules\@deepseek-ai\dsh\package.json') -Raw | ConvertFrom-Json).version
    Write-InstallLog "Harness 核心版本：$coreVersion。"
    Write-InstallLog '官方 Web UI：随 Harness 核心安装。'
    Write-InstallLog '已启用插件：sss-dsh-billing 0.1.5、sss-dsh-codex-reasoning 0.1.2。'
    Write-InstallLog (if ($NoLaunch) { '服务未启动（安装参数指定 NoLaunch）。' } else { '服务健康检查通过（HTTP 200）。' })
    Write-InstallLog '安装完成。桌面已创建“DeepSeek Harness 控制台.exe”。'
    Save-InstallReport
}
catch {
    Write-InstallLog "安装失败：$($_.Exception.Message)"
    Save-InstallReport
    Write-Error "安装未完成：$($_.Exception.Message)。安装报告：$reportPath"
    exit 1
}
