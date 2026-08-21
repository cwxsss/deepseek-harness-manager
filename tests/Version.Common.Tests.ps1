$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'Installer\payload\launcher\Version.Common.ps1')

function Assert-Equal {
    param([string]$Expected, [string]$Actual, [string]$Case)
    if ($Expected -ne $Actual) {
        throw "$Case：预期 $Expected，实际 $Actual"
    }
}

Assert-Equal '0.1.1-rc.1' (Select-LatestDshVersion @('0.1.0-rc.8', '0.1.1-rc.1')) '选择更高基础版本'
Assert-Equal '0.1.1' (Select-LatestDshVersion @('0.1.1-rc.9', '0.1.1')) '正式版高于同基础版本 RC'
Assert-Equal '0.1.1-rc.10' (Select-LatestDshVersion @('0.1.1-rc.9', '0.1.1-rc.10')) 'RC 序号按数字比较'
Assert-Equal '2.0.0-rc.1' (Select-LatestDshVersion @('invalid', '1.99.99', '2.0.0-beta.3', '2.0.0-rc.1')) '忽略不支持的版本格式'

$unsupportedFailed = $false
try {
    Select-LatestDshVersion @('invalid', '2.0.0-beta.3') | Out-Null
}
catch {
    $unsupportedFailed = $_.Exception.Message -match '无法识别可用的 DSH 已发布版本'
}
if (-not $unsupportedFailed) { throw '没有支持版本时未抛出明确错误。' }

Write-Output 'Version resolver tests passed (5 checks).'
