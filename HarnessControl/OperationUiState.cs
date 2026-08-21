namespace HarnessControl;

internal sealed record OperationUiState(
    bool Install,
    bool Start,
    bool Stop,
    bool Update,
    bool Uninstall,
    string Status,
    string Hint)
{
    public static OperationUiState ForRunning(string action, bool allowStop) => new(
        Install: false,
        Start: false,
        Stop: allowStop,
        Update: false,
        Uninstall: false,
        Status: $"状态：正在{action}…",
        Hint: allowStop
            ? $"正在{action}；如需中止，请点击“关闭 DeepSeek”。"
            : $"正在{action}；请等待当前操作完成。");

    public static OperationUiState ForStopping() => new(
        Install: false,
        Start: false,
        Stop: false,
        Update: false,
        Uninstall: false,
        Status: "状态：正在关闭…",
        Hint: "正在取消当前操作并关闭 DeepSeek；请等待关闭命令完成。");

    public static OperationUiState ForActivity(string? action, bool allowStop, bool stopInProgress)
    {
        if (stopInProgress) return ForStopping();
        if (action is null) throw new ArgumentNullException(nameof(action));
        return ForRunning(action, allowStop);
    }

    public static OperationUiState ForIdle(InstallationCondition installation, int httpStatus)
    {
        if (installation == InstallationCondition.None)
        {
            return new OperationUiState(
                Install: true,
                Start: false,
                Stop: false,
                Update: false,
                Uninstall: false,
                Status: "状态：未安装",
                Hint: "点击“安装 DeepSeek”开始安装；操作过程会写入下方日志和桌面报告。");
        }

        if (installation == InstallationCondition.Incomplete)
        {
            return new OperationUiState(
                Install: true,
                Start: false,
                Stop: false,
                Update: false,
                Uninstall: true,
                Status: "状态：安装不完整",
                Hint: "检测到残缺安装；请点击“安装 DeepSeek”修复，或点击“卸载 DeepSeek”清理。");
        }

        var responding = httpStatus > 0;
        var status = httpStatus == 200
            ? "状态：运行中（127.0.0.1:3080）"
            : responding
                ? $"状态：异常（HTTP {httpStatus}）"
                : "状态：未运行";
        return new OperationUiState(
            Install: true,
            Start: !responding,
            Stop: responding,
            Update: true,
            Uninstall: true,
            Status: status,
            Hint: "可启动、关闭、更新或卸载 DeepSeek；操作过程均写入下方日志和桌面报告。");
    }
}
