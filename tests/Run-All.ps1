$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-DotNetSdk {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $system = Get-Command 'dotnet.exe' -ErrorAction SilentlyContinue
    if ($null -ne $system) { $candidates.Add($system.Source) }
    $sharedSdk = Join-Path (Split-Path -Parent $repoRoot) '.dotnet-sdk\dotnet.exe'
    if (Test-Path -LiteralPath $sharedSdk -PathType Leaf) { $candidates.Add($sharedSdk) }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        $sdks = @(& $candidate --list-sdks 2>$null)
        if ($LASTEXITCODE -eq 0 -and $sdks.Count -gt 0) { return $candidate }
    }
    throw '未找到可用的 .NET SDK。需要 .NET 10 SDK，只有 .NET Runtime 不足以执行测试和构建。'
}

$dotnet = Resolve-DotNetSdk
Write-Output "Using .NET SDK: $dotnet"

& (Join-Path $PSScriptRoot 'Verify-Installer.ps1')

$realInstallScript = Join-Path $PSScriptRoot 'Verify-RealInstall.ps1'
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($realInstallScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "真实安装门禁脚本语法检查失败：$($parseErrors[0].Message)"
}
Write-Output 'Real install gate script parse passed (1 check).'

$testProject = Join-Path $repoRoot 'HarnessControl.Tests\HarnessControl.Tests.csproj'
& $dotnet build $testProject -c Release
if ($LASTEXITCODE -ne 0) { throw "管理器行为测试构建失败：$LASTEXITCODE" }
$testExe = Join-Path $repoRoot 'HarnessControl.Tests\bin\Release\net10.0-windows\win-x64\HarnessControl.Tests.exe'
if (-not (Test-Path -LiteralPath $testExe -PathType Leaf)) { throw "未生成测试程序：$testExe" }
& $testExe
if ($LASTEXITCODE -ne 0) { throw "管理器行为测试失败：$LASTEXITCODE" }

$managerProject = Join-Path $repoRoot 'HarnessControl\HarnessControl.csproj'
& $dotnet build $managerProject -c Release
if ($LASTEXITCODE -ne 0) { throw "Release 构建失败：$LASTEXITCODE" }

$publishRoot = Join-Path $repoRoot 'HarnessControl\bin\Release\verified-publish'
if (Test-Path -LiteralPath $publishRoot) {
    Remove-Item -LiteralPath $publishRoot -Recurse -Force
}
& $dotnet publish $managerProject -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:DebugType=None -p:DebugSymbols=false -o $publishRoot
if ($LASTEXITCODE -ne 0) { throw "单文件发布失败：$LASTEXITCODE" }

$publishedFiles = @(Get-ChildItem -LiteralPath $publishRoot -File)
if ($publishedFiles.Count -ne 1 -or $publishedFiles[0].Extension -ne '.exe') {
    throw "交付目录必须只包含一个 EXE，实际为：$($publishedFiles.Name -join '、')"
}
$header = [System.IO.File]::ReadAllBytes($publishedFiles[0].FullName)
if ($header.Length -lt 2 -or $header[0] -ne 0x4D -or $header[1] -ne 0x5A) {
    throw '发布文件不是有效的 Windows PE 可执行文件（缺少 MZ 文件头）。'
}

Write-Output "ALL_RELEASE_GATES_PASSED=$($publishedFiles[0].FullName)"
