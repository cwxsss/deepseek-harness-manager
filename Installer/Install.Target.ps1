function Test-DeepSeekManagerMetadata {
    param(
        [AllowEmptyString()][string]$ProductName,
        [AllowEmptyString()][string]$FileDescription
    )

    return $ProductName -eq 'DeepSeek Harness 控制台' -and
        $FileDescription -eq 'DeepSeek Harness 控制台'
}

function Test-ManagedDesktopController {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $metadata = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        return Test-DeepSeekManagerMetadata `
            -ProductName ([string]$metadata.ProductName) `
            -FileDescription ([string]$metadata.FileDescription)
    }
    catch {
        return $false
    }
}
