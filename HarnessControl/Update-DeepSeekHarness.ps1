param([switch]$PassThru)

$ErrorActionPreference = 'Stop'
$psStyleVariable = Get-Variable -Name PSStyle -ValueOnly -ErrorAction SilentlyContinue
if ($null -ne $psStyleVariable -and $null -ne $psStyleVariable.PSObject.Properties['OutputRendering']) {
    $psStyleVariable.OutputRendering = 'PlainText'
}
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$harnessRoot = Join-Path $env:LOCALAPPDATA 'DeepSeekHarness'
$launcherRoot = Join-Path $harnessRoot 'deepseek-harness-launcher'
$profileRoot = Join-Path $env:USERPROFILE '.dsh\profiles'
$webProfile = Join-Path $profileRoot 'web'
$nodeRoot = Join-Path $harnessRoot 'node-runtime\node-v22.17.1-win-x64'
$node = Join-Path $nodeRoot 'node.exe'
$corepack = Join-Path $nodeRoot 'corepack.cmd'
$snapshotRoot = $null
$stopped = $false
$started = $false
. (Join-Path $PSScriptRoot '..\Installer\payload\launcher\Version.Common.ps1')

function Write-UpdateLog { param([string]$Message) Write-Output ("[{0:HH:mm:ss}] [安全更新] {1}" -f (Get-Date), $Message) }
function Read-Json {
    param([string]$Path)
    $jsonText = $utf8.GetString([System.IO.File]::ReadAllBytes($Path)).TrimStart([char]0xFEFF)
    return $jsonText | ConvertFrom-Json
}
function Read-PackageVersion {
    param([string]$ManifestPath, [string]$PackageName)
    return [string](Read-Json $ManifestPath).dependencies.$PackageName
}
function Invoke-NativeChecked {
    param([string]$FilePath, [string[]]$Arguments, [string]$Label)
    Write-UpdateLog $Label
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Label 失败，退出码：$LASTEXITCODE。" }
}
function Save-ProfileSnapshot {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:snapshotRoot = Join-Path $launcherRoot "backups\plugin-safe-update-$stamp"
    New-Item -ItemType Directory -Path $script:snapshotRoot -Force | Out-Null
    foreach ($source in @(
        (Join-Path $profileRoot 'package.json'),
        (Join-Path $profileRoot 'pnpm-lock.yaml'),
        (Join-Path $profileRoot 'pnpm-workspace.yaml'),
        (Join-Path $webProfile 'package.json'),
        (Join-Path $webProfile 'pnpm-lock.yaml'),
        (Join-Path $webProfile 'pnpm-workspace.yaml')
    )) {
        if (Test-Path -LiteralPath $source) {
            $relative = $source.Substring($profileRoot.Length).TrimStart('\')
            $destination = Join-Path $script:snapshotRoot $relative
            New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
    }
    [pscustomobject]@{ CreatedAt = (Get-Date).ToString('O'); ProfileRoot = $profileRoot; WebProfile = $webProfile } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:snapshotRoot 'snapshot.json') -Encoding utf8
    Write-UpdateLog "已创建可回滚快照：$script:snapshotRoot"
}
function Restore-ProfileSnapshot {
    if ([string]::IsNullOrWhiteSpace($script:snapshotRoot) -or -not (Test-Path -LiteralPath $script:snapshotRoot)) {
        throw '未找到更新前快照，无法自动回滚。'
    }
    Write-UpdateLog '正在恢复更新前的 profile 清单和锁文件。'
    Get-ChildItem -LiteralPath $script:snapshotRoot -Recurse -File | Where-Object { $_.Name -ne 'snapshot.json' } | ForEach-Object {
        $relative = $_.FullName.Substring($script:snapshotRoot.Length).TrimStart('\')
        $destination = Join-Path $profileRoot $relative
        New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
    }
    Invoke-NativeChecked -FilePath $corepack -Arguments @('pnpm', '--color', 'never', '--dir', $profileRoot, 'install', '--frozen-lockfile') -Label '恢复 Harness profile 依赖'
    Invoke-NativeChecked -FilePath $corepack -Arguments @('pnpm', '--color', 'never', '--dir', $webProfile, 'install', '--frozen-lockfile') -Label '恢复 Web profile 依赖'
}
function Ensure-WebPluginBuildAllowlist {
    $workspaceFile = Join-Path $webProfile 'pnpm-workspace.yaml'
    if (-not (Test-Path -LiteralPath $workspaceFile)) { return }
    $yaml = $utf8.GetString([System.IO.File]::ReadAllBytes($workspaceFile)).TrimStart([char]0xFEFF)
    $nodePtyPattern = '(?m)^(\s*node-pty:\s*).*$'
    if ([regex]::IsMatch($yaml, $nodePtyPattern)) {
        $yaml = [regex]::Replace($yaml, $nodePtyPattern, '${1}true', 1)
    } elseif ([regex]::IsMatch($yaml, '(?m)^allowBuilds:\s*$')) {
        $yaml = [regex]::Replace($yaml, '(?m)^allowBuilds:\s*$', "allowBuilds:`r`n  node-pty: true", 1)
    } else {
        $yaml = $yaml.TrimEnd() + "`r`nallowBuilds:`r`n  node-pty: true`r`n"
    }
    [System.IO.File]::WriteAllText($workspaceFile, $yaml, $utf8)
    Write-UpdateLog '已确认 Web profile 允许 node-pty 构建脚本。'
}
function Resolve-PackagePath {
    param([string]$PackageName, [string]$FromDirectory)
    $current = $FromDirectory
    while ($true) {
        $candidate = Join-Path $current (Join-Path 'node_modules' $PackageName)
        if (Test-Path -LiteralPath (Join-Path $candidate 'package.json')) { return $candidate }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { return $null }
        $current = $parent
    }
}
function Get-WebClientPlugins {
    $rootManifest = Read-Json (Join-Path $webProfile 'package.json')
    $clients = @()
    foreach ($bundle in @($rootManifest.dsh.profile.bundles)) {
        if ([string]::IsNullOrWhiteSpace([string]$bundle)) { continue }
        $path = Resolve-PackagePath -PackageName ([string]$bundle) -FromDirectory $webProfile
        if ($null -eq $path) { throw "已启用 bundle 缺少包：$bundle" }
        $manifest = Read-Json (Join-Path $path 'package.json')
        if ($null -ne $manifest.dsh -and $null -ne $manifest.dsh.bundle -and $null -ne $manifest.dsh.client) {
            $clients += [pscustomobject]@{ Name = [string]$manifest.name; Path = $path }
        }
    }
    return @($clients | Sort-Object Name -Unique)
}
function Test-RunningWebPlugins {
    $root = Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 'http://127.0.0.1:3080/'
    if ($root.StatusCode -ne 200) { throw "Harness 首页异常，HTTP 状态：$($root.StatusCode)" }
    $nonce = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    foreach ($plugin in @(Get-WebClientPlugins)) {
        $url = "http://127.0.0.1:3080/plugins/$($plugin.Name)/client.js?health=$nonce"
        $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 $url -SkipHttpErrorCheck
        $contentType = [string]$response.Headers['Content-Type']
        if ($response.StatusCode -ne 200 -or $contentType -notmatch '^text/javascript' -or $response.Content.Length -lt 100) {
            throw "插件脚本验证失败：$($plugin.Name)（HTTP $($response.StatusCode)，Content-Type $contentType）。"
        }
    }
    Write-UpdateLog '首页及所有已启用客户端插件脚本验证通过。'
}

foreach ($path in @($node, $corepack, $profileRoot, $webProfile)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "缺少更新所需文件：$path" }
}

Write-UpdateLog '开始检查 DeepSeek Harness 更新。'
$currentCore = Read-PackageVersion -ManifestPath (Join-Path $profileRoot 'package.json') -PackageName '@deepseek-ai/dsh'
$latestCore = Get-LatestPublishedPackageVersion -CorepackPath $corepack -PackageName '@deepseek-ai/dsh'
Write-UpdateLog "Harness：当前 $currentCore，最新 $latestCore。"

$coreNeedsUpdate = $currentCore -ne $latestCore
if (-not $coreNeedsUpdate) {
    Test-RunningWebPlugins
    Write-UpdateLog '当前已是最新版本；服务与插件脚本验证通过，未重启。'
    if ($PassThru) { [pscustomobject]@{ HttpStatus = 200; Updated = $false; Latest = $true; Snapshot = $null } }
    return
}

Save-ProfileSnapshot
try {
    Write-UpdateLog '发现可用更新，正在安全停止服务。'
    & (Join-Path $launcherRoot 'Stop-DeepSeekHarness.ps1') -PassThru
    $stopped = $true
    Ensure-WebPluginBuildAllowlist
    if ($coreNeedsUpdate) { Invoke-NativeChecked -FilePath $corepack -Arguments @('pnpm', '--color', 'never', '--dir', $profileRoot, 'add', "@deepseek-ai/dsh@$latestCore") -Label "更新 Harness 核心至 $latestCore" }
    $cli = Join-Path $profileRoot 'node_modules\@deepseek-ai\dsh\lib\bin.js'
    Invoke-NativeChecked -FilePath $node -Arguments @($cli, '--version') -Label '验证 Harness 核心版本'
    & (Join-Path $launcherRoot 'Start-DeepSeekHarness.ps1') -PassThru
    $started = $true
    Test-RunningWebPlugins
    Write-UpdateLog '更新完成：服务及插件脚本均已验证通过。'
    if ($PassThru) { [pscustomobject]@{ HttpStatus = 200; Updated = $true; Latest = $false; Snapshot = $snapshotRoot } }
}
catch {
    $failure = $_
    Write-UpdateLog "更新验证失败：$($failure.Exception.Message)"
    $rollbackFailure = $null
    try {
        if ($stopped) { & (Join-Path $launcherRoot 'Stop-DeepSeekHarness.ps1') -PassThru | Out-Null }
        Restore-ProfileSnapshot
        & (Join-Path $launcherRoot 'Start-DeepSeekHarness.ps1') -PassThru | Out-Null
        Test-RunningWebPlugins
    }
    catch {
        $rollbackFailure = $_
    }
    if ($null -ne $rollbackFailure) { throw "更新失败，且自动回滚未完成：$($rollbackFailure.Exception.Message)；原始原因：$($failure.Exception.Message)；快照位置：$snapshotRoot" }
    throw "更新已自动回滚，旧版本已恢复并验证通过。原始原因：$($failure.Exception.Message)"
}




