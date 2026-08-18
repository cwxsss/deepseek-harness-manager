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
        $startOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $launcherRoot 'Start-DeepSeekHarness.ps1') -PassThru 2>&1
        $startOutput | ForEach-Object { Write-InstallLog ("启动日志：" + $_.ToString()) }
        if ($LASTEXITCODE -ne 0) { throw "启动脚本失败，退出码：$LASTEXITCODE" }
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
Require-Payload (Join-Path $payloadRoot 'plugins\sss-dsh-billing-0.1.2.tgz')
Require-Payload (Join-Path $payloadRoot 'plugins\sss-dsh-codex-reasoning-0.1.1.tgz')
$nodeExecutable = Join-Path $HarnessRoot 'node-runtime\node-v22.17.1-win-x64\node.exe'
$existingWebManifest = Join-Path $ProfileRoot 'web\package.json'
$canResume = (Test-Path -LiteralPath $nodeExecutable) -and (Test-Path -LiteralPath (Join-Path $ProfileRoot 'package.json')) -and (-not (Test-Path -LiteralPath $existingWebManifest))
if ((Test-Path -LiteralPath $HarnessRoot) -or (Test-Path -LiteralPath $ProfileRoot)) {
    if (-not $canResume) { throw "检测到已有 Harness 安装或配置。为保护现有内容，安装器不会覆盖它。" }
}
if ((Test-Path -LiteralPath $desktopController) -and (-not $canResume)) { throw "桌面已存在同名控制台：$desktopController。请先改名或移动该文件后重试。" }

try {
    if ($canResume) { Write-InstallLog '检测到上次核心安装未完成，正在从断点继续。' } else { Write-InstallLog '解压 Node 运行环境。' }
    New-Item -ItemType Directory -Path $HarnessRoot, $ProfileRoot, $localPluginRoot, $DesktopPath -Force | Out-Null
    if (-not (Test-Path -LiteralPath $nodeExecutable)) {
        $nodeArchive = Join-Path $payloadRoot 'node-runtime.tar'
        if (Test-Path -LiteralPath $nodeArchive -PathType Leaf) {
            & tar.exe -xf $nodeArchive -C $HarnessRoot
            if ($LASTEXITCODE -ne 0) { throw "Node 运行环境解压失败，退出码：$LASTEXITCODE" }
        }
        else {
            $nodeZip = Join-Path $packageRoot 'node-v22.17.1-win-x64.zip'
            Write-InstallLog '正在从 Node.js 官方下载运行环境（约 36 MB）。'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://nodejs.org/download/release/v22.17.1/node-v22.17.1-win-x64.zip' -OutFile $nodeZip
            Expand-Archive -LiteralPath $nodeZip -DestinationPath $HarnessRoot -Force
            Remove-Item -LiteralPath $nodeZip -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $nodeExecutable -PathType Leaf)) { throw 'Node 运行环境下载或解压失败。' }
        }
    }
    $launcherPayload = Join-Path $payloadRoot 'launcher'
    $launcherRoot = Join-Path $HarnessRoot 'deepseek-harness-launcher'
    New-Item -ItemType Directory -Path $launcherRoot -Force | Out-Null
    Get-ChildItem -LiteralPath $launcherPayload -Force | Copy-Item -Destination $launcherRoot -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $payloadRoot 'plugins\sss-dsh-billing-0.1.2.tgz'), (Join-Path $payloadRoot 'plugins\sss-dsh-codex-reasoning-0.1.1.tgz') -Destination $localPluginRoot -Force

    Write-InstallLog '下载并安装官方 Harness、Web UI 与两个本地插件。'
    $corepack = Join-Path $HarnessRoot 'node-runtime\node-v22.17.1-win-x64\corepack.cmd'
    $profileWorkspace = "packages:`n  - .`n`nnodeLinker: isolated`nautoInstallPeers: true`nallowBuilds:`n  '@deepseek-ai/dsh-subprocess-local': true`n  '@google/genai': true`n  koffi: true`n  node-pty: true`n  protobufjs: true"
    [System.IO.File]::WriteAllText((Join-Path $ProfileRoot 'pnpm-workspace.yaml'), $profileWorkspace, [System.Text.UTF8Encoding]::new($false))
    & $corepack pnpm --dir $ProfileRoot add '@deepseek-ai/dsh@0.1.0-rc.7' '@deepseek-ai/cordis-plugin-group@1.0.1'
    if ($LASTEXITCODE -ne 0) { throw "Harness 核心安装失败，退出码：$LASTEXITCODE" }
    & $corepack pnpm --dir $ProfileRoot rebuild --pending
    if ($LASTEXITCODE -ne 0) { throw "Harness 必需组件构建失败，退出码：$LASTEXITCODE" }
    $webManifest = @{
        name = 'dsh-profile-web'; private = $true
        dependencies = @{
            '@linxin666/dsh-web-ui-all' = '0.1.20'
            '@linxin666/dsh-client-ui-community-plugins' = '0.1.20'
            '@linxin666/dsh-client-ui-aionui-panel' = '0.1.20'
            '@linxin666/dsh-client-ui-task-board' = '0.1.20'
            '@linxin666/dsh-client-ui-git-graph' = '0.1.20'
            '@linxin666/dsh-pet' = '0.1.20'
            '@linxin666/dsh-remote-web-ui' = '0.1.20'
            '@linxin666/dsh-live-stats' = '0.1.20'
            '@linxin666/dsh-ssh' = '0.1.20'
            '@linxin666/dsh-tool-describe-image' = '0.1.20'
            '@linxin666/dsh-liangshen' = '0.1.20'
            '@linxin666/dsh-client-ui-web-ui-settings' = '0.1.20'
            '@linxin666/dsh-skins' = '0.1.20'
            '@linxin666/dsh-client-ui-skin-center' = '0.1.20'
            'sss-dsh-billing' = 'file:' + (Join-Path $localPluginRoot 'sss-dsh-billing-0.1.2.tgz').Replace('\', '/')
            'sss-dsh-codex-reasoning' = 'file:' + (Join-Path $localPluginRoot 'sss-dsh-codex-reasoning-0.1.1.tgz').Replace('\', '/')
        }
        dsh = @{ profile = @{ bundles = @('@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', 'sss-dsh-billing', 'sss-dsh-codex-reasoning', '@linxin666/dsh-web-ui-all') } }
    }
    $webRoot = Join-Path $ProfileRoot 'web'
    New-Item -ItemType Directory -Path $webRoot -Force | Out-Null
    $webManifestJson = $webManifest | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText((Join-Path $webRoot 'package.json'), $webManifestJson, [System.Text.UTF8Encoding]::new($false))
    $webWorkspace = "packages:`n  - .`n`nnodeLinker: isolated`nautoInstallPeers: true`nallowBuilds:`n  cloudflared: true`n  cpu-features: true`n  ssh2: true"
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
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $launcherRoot 'Start-DeepSeekHarness.ps1') -PassThru 2>&1 | ForEach-Object { Write-InstallLog ("启动日志：" + $_.ToString()) }
        if ($LASTEXITCODE -ne 0) { throw "启动脚本失败，退出码：$LASTEXITCODE" }
        if ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 'http://127.0.0.1:3080/').StatusCode -ne 200) { throw '服务健康检查失败。' }
    }
    $coreVersion = (Get-Content -LiteralPath (Join-Path $ProfileRoot 'node_modules\@deepseek-ai\dsh\package.json') -Raw | ConvertFrom-Json).version
    $webVersion = (Get-Content -LiteralPath (Join-Path $webRoot 'package.json') -Raw | ConvertFrom-Json).dependencies.'@linxin666/dsh-web-ui-all'
    Write-InstallLog "Harness 核心版本：$coreVersion。"
    Write-InstallLog "Web UI 版本：$webVersion。"
    Write-InstallLog '已启用插件：sss-dsh-billing 0.1.2、sss-dsh-codex-reasoning 0.1.1。'
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
