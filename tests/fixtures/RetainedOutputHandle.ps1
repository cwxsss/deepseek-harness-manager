param([Parameter(Mandatory = $true)][string]$PidFile)

$ErrorActionPreference = 'Stop'
$pwsh = (Get-Command 'pwsh.exe' -ErrorAction Stop).Source
$child = Start-Process -FilePath $pwsh `
    -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') `
    -NoNewWindow -PassThru
[System.IO.File]::WriteAllText($PidFile, $child.Id.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Output 'Parent PowerShell completed while child retains inherited output handles.'
