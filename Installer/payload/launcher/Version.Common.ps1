function Select-LatestDshVersion {
    param([string[]]$Versions)

    $parsedVersions = foreach ($version in @($Versions)) {
        $text = [string]$version
        if ($text -match '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-rc\.(?<pre>\d+))?$') {
            [pscustomobject]@{
                Text = $text
                Major = [int]$Matches.major
                Minor = [int]$Matches.minor
                Patch = [int]$Matches.patch
                Stable = if ([string]::IsNullOrEmpty($Matches.pre)) { 1 } else { 0 }
                Pre = if ([string]::IsNullOrEmpty($Matches.pre)) { 0 } else { [int]$Matches.pre }
            }
        }
    }

    $latest = $parsedVersions | Sort-Object `
        @{ Expression = { $_.Major }; Descending = $true }, `
        @{ Expression = { $_.Minor }; Descending = $true }, `
        @{ Expression = { $_.Patch }; Descending = $true }, `
        @{ Expression = { $_.Stable }; Descending = $true }, `
        @{ Expression = { $_.Pre }; Descending = $true } |
        Select-Object -First 1
    if ($null -eq $latest) { throw '无法识别可用的 DSH 已发布版本。' }
    return [string]$latest.Text
}

function Get-LatestPublishedPackageVersion {
    param(
        [Parameter(Mandatory = $true)][string]$CorepackPath,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    $rawVersions = & $CorepackPath pnpm --color never view $PackageName versions --json
    if ($LASTEXITCODE -ne 0 -or $null -eq $rawVersions) {
        throw "无法读取 $PackageName 的已发布版本列表。"
    }
    try {
        $publishedVersions = @((($rawVersions -join [Environment]::NewLine) | ConvertFrom-Json))
    }
    catch {
        throw "无法解析 $PackageName 的已发布版本列表：$($_.Exception.Message)"
    }
    return Select-LatestDshVersion -Versions $publishedVersions
}
