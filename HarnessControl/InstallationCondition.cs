namespace HarnessControl;

internal enum InstallationCondition
{
    None,
    Incomplete,
    Complete,
}

internal static class InstallationConditionDetector
{
    public static InstallationCondition Detect(string harnessRoot, string profileRoot, string localPluginRoot)
    {
        var anyInstallationData = Directory.Exists(harnessRoot) ||
            Directory.Exists(profileRoot) ||
            Directory.Exists(localPluginRoot);
        if (!anyInstallationData) return InstallationCondition.None;

        var requiredFiles = new[]
        {
            Path.Combine(harnessRoot, "node-runtime", "node-v22.17.1-win-x64", "node.exe"),
            Path.Combine(harnessRoot, "deepseek-harness-launcher", "Start-DeepSeekHarness.ps1"),
            Path.Combine(harnessRoot, "deepseek-harness-launcher", "Stop-DeepSeekHarness.ps1"),
            Path.Combine(harnessRoot, "deepseek-harness-launcher", "Update-DeepSeekHarness.ps1"),
            Path.Combine(profileRoot, "node_modules", "@deepseek-ai", "dsh", "package.json"),
            Path.Combine(profileRoot, "web", "package.json"),
            Path.Combine(localPluginRoot, "packages", "sss-dsh-billing-0.1.5.tgz"),
            Path.Combine(localPluginRoot, "packages", "sss-dsh-codex-reasoning-0.1.2.tgz"),
        };
        return requiredFiles.All(File.Exists)
            ? InstallationCondition.Complete
            : InstallationCondition.Incomplete;
    }
}
