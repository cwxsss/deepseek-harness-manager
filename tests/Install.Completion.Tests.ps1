$ErrorActionPreference = 'Stop'

$helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'Installer\Install.Completion.ps1'
. $helper

$notStarted = Get-InstallServiceCompletionMessage -NoLaunch $true
$healthy = Get-InstallServiceCompletionMessage -NoLaunch $false

if ($notStarted -ne '服务未启动（安装参数指定 NoLaunch）。') {
    throw "NoLaunch 文案错误：$notStarted"
}
if ($healthy -ne '服务健康检查通过（HTTP 200）。') {
    throw "健康文案错误：$healthy"
}

Write-Output 'Install completion behavior tests passed (2 checks).'
