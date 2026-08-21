$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $repoRoot 'Installer\Install-DeepSeekHarness.ps1'
$tokens = $null
$errors = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    throw "安装脚本语法检查失败：$($errors[0].Message)"
}

$nestedPowerShellLaunchers = @($installerAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ieq 'pwsh.exe'
}, $true))
if ($nestedPowerShellLaunchers.Count -gt 0) {
    throw '安装器不得通过嵌套 pwsh.exe 调用启动脚本，否则后台服务会继承输出管道并阻塞安装收尾。'
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

$fixture = Join-Path $PSScriptRoot 'fixtures\LongRunningLauncher.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-launcher-test-' + [guid]::NewGuid().ToString('N'))
$pidFile = Join-Path $testRoot 'service.pid'
$servicePid = $null
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = & $fixture -PidFile $pidFile -LogRoot $testRoot
    $stopwatch.Stop()
    $servicePid = [int](Get-Content -LiteralPath $pidFile -Raw)
    if ($stopwatch.Elapsed.TotalSeconds -ge 5) { throw "启动脚本未及时返回：$($stopwatch.Elapsed.TotalSeconds) 秒" }
    if ($result.ProcessId -ne $servicePid -or -not $result.Healthy) { throw '启动脚本返回结果不正确。' }
}
finally {
    if ($null -ne $servicePid) { Stop-Process -Id $servicePid -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "Installer regression checks passed ($($checks.Count + 2) checks)."
