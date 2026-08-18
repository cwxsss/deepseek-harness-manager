param([switch]$PassThru)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Launcher.Common.ps1')

Write-HarnessLog '检查正在运行的 Harness 服务。'
$state = Read-HarnessState
$reportedProcessId = if ($null -ne $state) { [int]$state.processId } else { 0 }
$process = if ($null -ne $state) { Get-ValidatedHarnessProcess -State $state } else { $null }
if ($null -eq $process) {
    $listeners = @(Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue)
    foreach ($listener in $listeners) {
        $candidate = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        if ($null -eq $candidate) { continue }
        try {
            $info = Get-CimInstance Win32_Process -Filter "ProcessId = $($candidate.Id)" -ErrorAction Stop
            if ($info.CommandLine -match '(apps[\\/]cli[\\/]src[\\/]bin\.ts|@deepseek-ai[\\/]dsh[\\/]lib[\\/]bin\.js)' -and $info.CommandLine -match '\bweb\b' -and $info.CommandLine -match '--port(?:=|\s+)3080\b') { $process = $candidate; break }
        } catch { }
    }
}
if ($null -eq $process) {
    Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue
    Write-HarnessLog '服务当前未运行，无需关闭。'
    if ($PassThru) { [pscustomobject]@{ ProcessId = $reportedProcessId; Stopped = $false } }
    return
}
$processId = $process.Id
Write-HarnessLog "正在停止服务进程（PID $processId）及其子进程。"
& taskkill.exe /PID $processId /T /F | Out-Null
if ($LASTEXITCODE -ne 0) { throw "停止服务失败，退出码：$LASTEXITCODE" }
Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue
Write-HarnessLog '服务已停止，端口 3080 已释放。'
if ($PassThru) { [pscustomobject]@{ ProcessId = $processId; Stopped = $true } }
