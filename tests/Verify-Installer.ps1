$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'Version.Common.Tests.ps1')
& (Join-Path $PSScriptRoot 'Install.Completion.Tests.ps1')
& (Join-Path $PSScriptRoot 'Install.Target.Tests.ps1')

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

$payloadUpdater = Get-Content -LiteralPath (Join-Path $repoRoot 'Installer\payload\launcher\Update-DeepSeekHarness.ps1') -Raw
$sourceUpdater = Get-Content -LiteralPath (Join-Path $repoRoot 'HarnessControl\Update-DeepSeekHarness.ps1') -Raw
$project = Get-Content -LiteralPath (Join-Path $repoRoot 'HarnessControl\HarnessControl.csproj') -Raw
$program = Get-Content -LiteralPath (Join-Path $repoRoot 'HarnessControl\Program.cs') -Raw
$wiringChecks = [ordered]@{
    'Installer uses executable completion helper' = $installer -match 'Get-InstallServiceCompletionMessage' -and $installer -notmatch 'Write-InstallLog\s*\(if\s*\('
    'Project embeds install completion helper' = $project -match 'HarnessControl\.Resources\.Install\.Completion\.ps1'
    'Manager extracts install completion helper' = $program -match 'HarnessControl\.Resources\.Install\.Completion\.ps1'
    'Installer validates existing desktop controller ownership' = $installer -match 'Test-ManagedDesktopController'
    'Project embeds install target helper' = $project -match 'HarnessControl\.Resources\.Install\.Target\.ps1'
    'Manager extracts install target helper' = $program -match 'HarnessControl\.Resources\.Install\.Target\.ps1'
    'Installer resolves latest published DSH' = $installer -match 'Get-LatestPublishedPackageVersion' -and $installer -notmatch '@deepseek-ai/dsh@0\.1\.1-rc\.1'
    'Runtime updater uses shared resolver' = $payloadUpdater -match 'Version\.Common\.ps1' -and $payloadUpdater -match 'Get-LatestPublishedPackageVersion'
    'Source updater uses shared resolver' = $sourceUpdater -match 'Version\.Common\.ps1' -and $sourceUpdater -match 'Get-LatestPublishedPackageVersion'
    'Project embeds version resolver' = $project -match 'HarnessControl\.Resources\.Version\.Common\.ps1'
    'Manager extracts version resolver' = $program -match 'HarnessControl\.Resources\.Version\.Common\.ps1'
}
$wiringFailures = @($wiringChecks.GetEnumerator() | Where-Object { -not $_.Value })
if ($wiringFailures.Count -gt 0) {
    throw "最新版安装接线检查失败：$($wiringFailures.Name -join '、')"
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

Write-Output "Installer regression checks passed ($($checks.Count + $wiringChecks.Count + 2) checks)."
