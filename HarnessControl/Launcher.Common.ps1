$script:RepositoryPath = 'C:\Users\chuai\AppData\Local\DeepSeekHarness'
$script:HarnessUrl = 'http://127.0.0.1:3080/'
$script:StatePath = 'C:\Users\chuai\AppData\Local\DeepSeekHarness\deepseek-harness-launcher\deepseek-harness.state.json'
$script:StdoutPath = 'C:\Users\chuai\AppData\Local\DeepSeekHarness\deepseek-harness-launcher\deepseek-harness.stdout.log'
$script:StderrPath = 'C:\Users\chuai\AppData\Local\DeepSeekHarness\deepseek-harness-launcher\deepseek-harness.stderr.log'

function Write-HarnessLog { param([string]$Message) Write-Output ("[{0:HH:mm:ss}] [服务] {1}" -f (Get-Date), $Message) }
function Get-HarnessHttpStatus { try { return [int](Invoke-WebRequest -Uri $script:HarnessUrl -UseBasicParsing -TimeoutSec 2).StatusCode } catch { return 0 } }
function Read-HarnessState { if (-not (Test-Path -LiteralPath $script:StatePath)) { return $null }; try { return Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json } catch { Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue; return $null } }
function Get-ValidatedHarnessProcess {
    param([Parameter(Mandatory = $true)]$State)
    if ($State.repositoryPath -ne $script:RepositoryPath -or $State.url -ne $script:HarnessUrl) { return $null }
    $process = Get-Process -Id ([int]$State.processId) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    try {
        if ([math]::Abs((($process.StartTime.ToUniversalTime() - ([datetime]$State.startTimeUtc).ToUniversalTime()).TotalMilliseconds)) -gt 100) { return $null }
        $info = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop
        if ($info.CommandLine -notmatch '(apps[\\/]cli[\\/]src[\\/]bin\.ts|@deepseek-ai[\\/]dsh[\\/]lib[\\/]bin\.js)' -or $info.CommandLine -notmatch '\bweb\b') { return $null }
        return $process
    } catch { return $null }
}
