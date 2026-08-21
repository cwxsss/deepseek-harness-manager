function Get-InstallServiceCompletionMessage {
    param([Parameter(Mandatory = $true)][bool]$NoLaunch)

    if ($NoLaunch) {
        return '服务未启动（安装参数指定 NoLaunch）。'
    }

    return '服务健康检查通过（HTTP 200）。'
}
