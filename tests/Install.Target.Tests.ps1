$ErrorActionPreference = 'Stop'

$helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'Installer\Install.Target.ps1'
. $helper

if (-not (Test-DeepSeekManagerMetadata -ProductName 'DeepSeek Harness 控制台' -FileDescription 'DeepSeek Harness 控制台')) {
    throw '上一版 DeepSeek 管理器产品元数据必须允许安全覆盖。'
}
if (Test-DeepSeekManagerMetadata -ProductName '其他程序' -FileDescription 'DeepSeek Harness 控制台') {
    throw '产品名不匹配的同名文件不得覆盖。'
}
if (Test-DeepSeekManagerMetadata -ProductName 'DeepSeek Harness 控制台' -FileDescription '其他程序') {
    throw '文件描述不匹配的同名文件不得覆盖。'
}

$tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-unrelated-' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    [System.IO.File]::WriteAllText($tempFile, 'not a manager executable')
    if (Test-ManagedDesktopController -Path $tempFile) { throw '普通同名文件不得识别为可覆盖的旧管理器。' }
}
finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}

Write-Output 'Install target behavior tests passed (4 checks).'
