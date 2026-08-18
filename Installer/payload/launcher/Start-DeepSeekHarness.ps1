param([switch]$PassThru)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Launcher.Common.ps1')

Write-HarnessLog '检查 DeepSeek Harness 服务状态。'
$status = Get-HarnessHttpStatus
if ($status -eq 200) {
    Write-HarnessLog '服务已在运行（HTTP 200），无需重复启动。'
    if ($PassThru) { [pscustomobject]@{ HttpStatus = 200; Reused = $true } }
    return
}
Write-HarnessLog '检查端口 3080。'
if (Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue) { throw '端口 3080 已被其他程序占用。' }
$harnessNode = Join-Path $script:RepositoryPath 'node-runtime\node-v22.17.1-win-x64\node.exe'
$node = if (Test-Path -LiteralPath $harnessNode -PathType Leaf) { [pscustomobject]@{ Source = $harnessNode } } else { Get-Command 'node.exe' -ErrorAction SilentlyContinue }
if ($null -eq $node) { throw '未找到 node.exe，请先安装 Node.js。' }
$dshCli = Join-Path $env:USERPROFILE '.dsh\profiles\node_modules\@deepseek-ai\dsh\lib\bin.js'
if (-not (Test-Path -LiteralPath $dshCli -PathType Leaf)) { throw "未找到 dsh CLI：$dshCli" }
Write-HarnessLog "运行环境就绪：$($node.Source)"
Remove-Item -LiteralPath $script:StdoutPath, $script:StderrPath -Force -ErrorAction SilentlyContinue
Write-HarnessLog '正在启动 Harness 核心、Web UI 与已启用插件。'
$process = Start-Process -FilePath $node.Source -ArgumentList @($dshCli, 'web', '--host', '127.0.0.1', '--port', '3080') -WorkingDirectory ([System.IO.Path]::GetDirectoryName($dshCli)) -WindowStyle Hidden -RedirectStandardOutput $script:StdoutPath -RedirectStandardError $script:StderrPath -PassThru
[pscustomobject]@{ processId = $process.Id; startTimeUtc = $process.StartTime.ToUniversalTime().ToString('O'); repositoryPath = $script:RepositoryPath; url = $script:HarnessUrl } | ConvertTo-Json | Set-Content -LiteralPath $script:StatePath -Encoding utf8
Write-HarnessLog "服务进程已创建（PID $($process.Id)），等待健康检查。"
$readLaunchDiagnostics = {
    $messages = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @(
        @{ Label = '标准错误'; Path = $script:StderrPath },
        @{ Label = '标准输出'; Path = $script:StdoutPath }
    )) {
        if (Test-Path -LiteralPath $entry.Path) {
            $tail = @(Get-Content -LiteralPath $entry.Path -Tail 20 -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($tail.Count -gt 0) { $messages.Add("$($entry.Label)：" + ($tail -join ' | ')) }
        }
    }
    return ($messages -join '；')
}
$deadline = (Get-Date).AddSeconds(120)
$nextProgress = (Get-Date).AddSeconds(5)
while ((Get-Date) -lt $deadline) {
    if ($process.HasExited) {
        $exitCode = try { $process.ExitCode } catch { '未知' }
        $diagnostics = & $readLaunchDiagnostics
        if ([string]::IsNullOrWhiteSpace($diagnostics)) { $diagnostics = '未生成可用的核心进程日志。' }
        throw "DeepSeek Harness 启动进程提前退出，退出码：$exitCode。$diagnostics"
    }
    if ((Get-HarnessHttpStatus) -eq 200) {
        Write-HarnessLog '服务健康检查通过（HTTP 200）。'
        if (Test-Path -LiteralPath $script:StdoutPath) { Get-Content -LiteralPath $script:StdoutPath -Tail 10 | ForEach-Object { Write-HarnessLog "组件日志：$_" } }
        if (Test-Path -LiteralPath $script:StderrPath) { Get-Content -LiteralPath $script:StderrPath -Tail 10 | ForEach-Object { Write-HarnessLog "组件告警：$_" } }
        if ($PassThru) { [pscustomobject]@{ ProcessId = $process.Id; HttpStatus = 200; Reused = $false } }
        return
    }
    if ((Get-Date) -ge $nextProgress) { Write-HarnessLog '服务仍在初始化，继续等待健康检查。'; $nextProgress = (Get-Date).AddSeconds(5) }
    Start-Sleep -Milliseconds 500
}
$diagnostics = & $readLaunchDiagnostics
if ([string]::IsNullOrWhiteSpace($diagnostics)) { throw '等待 DeepSeek Harness 启动超时，未生成可用的核心进程日志。' }
throw "等待 DeepSeek Harness 启动超时。$diagnostics"
