param(
    [Parameter(Mandatory = $true)][string]$PidFile,
    [Parameter(Mandatory = $true)][string]$LogRoot
)

$ErrorActionPreference = 'Stop'
$pwsh = (Get-Command 'pwsh.exe' -ErrorAction Stop).Source
$stdout = Join-Path $LogRoot 'service.stdout.log'
$stderr = Join-Path $LogRoot 'service.stderr.log'
$process = Start-Process -FilePath $pwsh `
    -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 20') `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
Set-Content -LiteralPath $PidFile -Value $process.Id
[pscustomobject]@{ ProcessId = $process.Id; Healthy = $true }
