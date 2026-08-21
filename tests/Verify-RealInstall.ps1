param(
    [Parameter(Mandatory = $true)][string]$ManagerExe,
    [switch]$ConfirmRealInstall
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmRealInstall) {
    throw '必须显式传入 -ConfirmRealInstall；该测试会停止并替换当前 DSH 安装。'
}

$managerPath = (Resolve-Path -LiteralPath $ManagerExe -ErrorAction Stop).Path
if ([System.IO.Path]::GetExtension($managerPath) -ne '.exe') {
    throw "管理器候选文件必须是 EXE：$managerPath"
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NativeButtonClick
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
}
'@

function Get-MainWindowElement {
    param([System.Diagnostics.Process]$Process, [int]$TimeoutSeconds = 20)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) { throw "管理器在显示窗口前退出，退出码：$($Process.ExitCode)" }
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            $element = [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
            if ($null -ne $element) { return $element }
        }
        Start-Sleep -Milliseconds 200
    }
    throw '等待管理器主窗口超时。'
}

function Find-NamedButton {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Name
    )

    $conditions = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            $Name))
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $conditions)
}

function Invoke-AutomationButton {
    param([System.Windows.Automation.AutomationElement]$Button)

    if ($null -eq $Button) { throw '找不到需要点击的按钮。' }
    $handle = [IntPtr]$Button.Current.NativeWindowHandle
    if ($handle -eq [IntPtr]::Zero) { throw "按钮没有可用的窗口句柄：$($Button.Current.Name)" }
    if (-not [NativeButtonClick]::PostMessage($handle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)) {
        throw "无法投递按钮点击：$($Button.Current.Name)"
    }
}

function Confirm-OwnedDialogs {
    param([int]$ProcessId, [int]$MainWindowHandle)

    $processCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
        $ProcessId)
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        $processCondition)
    foreach ($window in $windows) {
        if ($window.Current.NativeWindowHandle -eq $MainWindowHandle) { continue }
        $buttons = $window.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Button))
        foreach ($button in $buttons) {
            if ($button.Current.Name -match '^(是|Yes|确定|OK)') {
                Invoke-AutomationButton -Button $button
                break
            }
        }
    }
}

function Get-StatusText {
    param([System.Windows.Automation.AutomationElement]$Root)

    $texts = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Text))
    foreach ($text in $texts) {
        if ($text.Current.Name -like '状态：*') { return $text.Current.Name }
    }
    return ''
}

function Get-UiLogText {
    param([System.Windows.Automation.AutomationElement]$Root)

    $edits = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Edit))
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($edit in $edits) {
        try {
            $pattern = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            $value = ([System.Windows.Automation.ValuePattern]$pattern).Current.Value
            if (-not [string]::IsNullOrWhiteSpace($value)) { $values.Add($value) }
        }
        catch { }
    }
    return ($values -join "`n")
}

$process = $null
$statusText = ''
$uiLog = ''
try {
    $process = Start-Process -FilePath $managerPath -PassThru
    $window = Get-MainWindowElement -Process $process
    $installButton = Find-NamedButton -Root $window -Name '安装 DeepSeek'
    if (-not $installButton.Current.IsEnabled) {
        throw '候选管理器的安装按钮在空闲状态不可用。'
    }
    Invoke-AutomationButton -Button $installButton

    $sawInstalling = $false
    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { throw "管理器在安装完成前退出，退出码：$($process.ExitCode)" }
        Confirm-OwnedDialogs -ProcessId $process.Id -MainWindowHandle $process.MainWindowHandle
        $statusText = Get-StatusText -Root $window
        $uiLog = Get-UiLogText -Root $window
        if ($statusText -like '*正在安装*') { $sawInstalling = $true }

        $closeButton = Find-NamedButton -Root $window -Name '关闭 DeepSeek'
        $updateButton = Find-NamedButton -Root $window -Name '更新 DeepSeek'
        $finished = $sawInstalling -and
            $statusText -notlike '*正在*' -and
            $uiLog -like '*安装完成*' -and
            $null -ne $closeButton -and $closeButton.Current.IsEnabled -and
            $null -ne $updateButton -and $updateButton.Current.IsEnabled
        if ($finished) { break }
        Start-Sleep -Milliseconds 500
    }

    if (-not $sawInstalling) { throw '未观察到“正在安装”状态，真实安装流程没有被执行。' }
    if ($statusText -like '*正在*') { throw "安装超时或 UI 未收尾，最终状态：$statusText" }
    if ($uiLog -notlike '*安装完成*') { throw '管理器日志没有出现“安装完成”。' }

    $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 'http://127.0.0.1:3080/'
    if ($response.StatusCode -ne 200) { throw "Harness 健康检查失败：HTTP $($response.StatusCode)" }

    $profileRoot = Join-Path $env:USERPROFILE '.dsh\profiles'
    $installedManifest = Join-Path $profileRoot 'node_modules\@deepseek-ai\dsh\package.json'
    $installedVersion = (Get-Content -LiteralPath $installedManifest -Raw | ConvertFrom-Json).version
    $corepack = Join-Path $env:LOCALAPPDATA 'DeepSeekHarness\node-runtime\node-v22.17.1-win-x64\corepack.cmd'
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Installer\payload\launcher\Version.Common.ps1')
    $latestVersion = Get-LatestPublishedPackageVersion -CorepackPath $corepack -PackageName '@deepseek-ai/dsh'
    if ($installedVersion -ne $latestVersion) {
        throw "安装版本不是当前最高已发布版本：已安装 $installedVersion，当前最高 $latestVersion"
    }

    $closeButton = Find-NamedButton -Root $window -Name '关闭 DeepSeek'
    $updateButton = Find-NamedButton -Root $window -Name '更新 DeepSeek'
    if (-not $closeButton.Current.IsEnabled -or -not $updateButton.Current.IsEnabled) {
        throw '安装完成后关闭或更新按钮仍不可用。'
    }

    Write-Output "REAL_INSTALL_VERIFIED_VERSION=$installedVersion"
    Write-Output "REAL_INSTALL_VERIFIED_STATUS=$statusText"
    Write-Output 'REAL_INSTALL_VERIFIED_HTTP=200'
    Write-Output 'REAL_INSTALL_VERIFIED_BUTTONS=Close,Update'
}
catch {
    $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    Write-Error "真实安装验证失败：$($_.Exception.Message)`n最终状态：$statusText`n安装报告：$(Join-Path $desktop 'DeepSeek Harness 安装报告.txt')`nHarness 日志：$(Join-Path $env:LOCALAPPDATA 'DeepSeekHarness\deepseek-harness-launcher')"
    throw
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        [void]$process.CloseMainWindow()
        if (-not $process.WaitForExit(5000)) {
            Write-Warning "候选管理器未在五秒内关闭，正在精确结束测试创建的 PID $($process.Id)。"
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            [void]$process.WaitForExit(5000)
        }
    }
}
