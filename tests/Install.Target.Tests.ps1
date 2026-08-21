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
if (-not (Test-SafeDesktopControllerAttributes -Attributes ([System.IO.FileAttributes]::ReparsePoint) -LinkTarget $null)) {
    throw '不指向其他路径的同步元数据重解析点必须允许继续验证产品元数据。'
}
if (Test-SafeDesktopControllerAttributes -Attributes ([System.IO.FileAttributes]::ReparsePoint) -LinkTarget '..\outside.exe') {
    throw '桌面控制台目标是符号链接时不得覆盖。'
}
if (-not (Test-SafeDesktopControllerAttributes -Attributes ([System.IO.FileAttributes]::Archive))) {
    throw '普通文件属性必须允许继续验证产品元数据。'
}

$samePath = Join-Path ([System.IO.Path]::GetTempPath()) 'DeepSeek Harness 控制台.exe'
if (-not (Test-SameFilePath -First $samePath -Second $samePath.ToUpperInvariant())) {
    throw 'Windows 同一路径比较必须忽略大小写。'
}
if (Test-SameFilePath -First $samePath -Second ($samePath + '.other')) {
    throw '不同路径不得识别为管理器自覆盖。'
}

$tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-unrelated-' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    [System.IO.File]::WriteAllText($tempFile, 'not a manager executable')
    if (Test-ManagedDesktopController -Path $tempFile) { throw '普通同名文件不得识别为可覆盖的旧管理器。' }
}
finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}

Write-Output 'Install target behavior tests passed (9 checks).'
