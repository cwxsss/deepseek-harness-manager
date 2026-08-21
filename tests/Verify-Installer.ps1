$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $repoRoot 'Installer\Install-DeepSeekHarness.ps1'
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    throw "安装脚本语法检查失败：$($errors[0].Message)"
}

$installer = Get-Content -LiteralPath $installerPath -Raw
$checks = [ordered]@{
    'ZIP uses a temporary extraction root' = $installer -match 'Expand-Archive -LiteralPath \$nodeZip -DestinationPath \$extractRoot'
    'Extracted Node is moved under node-runtime' = $installer -match 'Move-Item -LiteralPath \$extractedNodeRoot -Destination \$nodeRuntimeRoot'
    'Legacy root runtime is migrated' = $installer -match '\$hasLegacyNodeRuntime'
    'Partial installation can resume' = $installer -match '\$hasPartialInstall'
    'Final Node path is validated' = $installer -match 'Node 运行环境未就绪'
}

$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value })
if ($failed.Count -gt 0) {
    throw "安装器回归检查失败：$($failed.Name -join '、')"
}

Write-Output "Installer regression checks passed ($($checks.Count) checks)."
