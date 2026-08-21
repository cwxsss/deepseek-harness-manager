function Test-DeepSeekManagerMetadata {
    param(
        [AllowEmptyString()][string]$ProductName,
        [AllowEmptyString()][string]$FileDescription
    )

    return $ProductName -eq 'DeepSeek Harness 控制台' -and
        $FileDescription -eq 'DeepSeek Harness 控制台'
}

function Test-SafeDesktopControllerAttributes {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileAttributes]$Attributes,
        [AllowNull()][string]$LinkTarget
    )

    if (($Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { return $true }
    return [string]::IsNullOrWhiteSpace($LinkTarget)
}

function Test-SameFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second
    )

    try {
        $firstFullPath = [System.IO.Path]::GetFullPath($First).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        $secondFullPath = [System.IO.Path]::GetFullPath($Second).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        return [string]::Equals($firstFullPath, $secondFullPath, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Test-ManagedDesktopController {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not (Test-SafeDesktopControllerAttributes -Attributes $item.Attributes -LinkTarget ([string]$item.LinkTarget))) { return $false }
        $metadata = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        return Test-DeepSeekManagerMetadata `
            -ProductName ([string]$metadata.ProductName) `
            -FileDescription ([string]$metadata.FileDescription)
    }
    catch {
        return $false
    }
}
