# DeepSeek Harness Manager

A Windows desktop manager for a local DeepSeek Harness installation. It provides a compact console for starting, stopping, and safely updating Harness.

## Features

- Start and stop the local Harness service on `127.0.0.1:3080`.
- Check for and install official Harness updates.
- Create a timestamped profile snapshot before an update.
- Validate the homepage and enabled top-level plugin scripts after an update.
- Automatically restore the previous profile state when an update fails validation.
- Validate the enabled SSS plugin scripts after an update, preventing broken local plugin links from starting silently.

## Project layout

- `HarnessControl/` — Windows Forms control application.
- `Installer/` — portable installation and repair scripts, launcher templates, and the bundled billing/reasoning plugins.

The repository deliberately excludes generated binaries, Node.js runtimes, dependency folders, local profiles, logs, and personal configuration.

## Distribution

The end-user distribution is a single self-contained Windows x64 executable: `DeepSeek Harness 控制台.exe`. The installer script, launcher scripts, and the two SSS plugin packages are embedded in this executable, so users do not need to receive the `payload` folder, `.cmd` files, `.ps1` files, or `.tgz` files separately. Run the executable and choose **安装 DeepSeek**; the same window then provides installation, start, stop, update, and uninstall operations.

The ZIP/portable folder is optional and intended for development, backup, or batch distribution. It is not required for normal end-user installation. The executable still requires PowerShell 7 and an internet connection for the initial official Harness download (and for Node.js when the target machine does not already have it).

## Build

Requirements: Windows, PowerShell 7 (`pwsh.exe`), and the .NET 10 SDK.

```powershell
pwsh -NoProfile -File .\tests\Run-All.ps1
```

`Run-All.ps1` executes the PowerShell installer checks, real process-lifecycle tests, button-state tests, Release build, and single-file publish verification. The generated verification directory must contain exactly one Windows EXE. A failed check blocks delivery even when the Harness homepage already returns HTTP 200.

Pull requests and pushes to `main` run the same gate on a GitHub-hosted Windows runner. The workflow uses the current official `actions/checkout@v7` and `actions/setup-dotnet@v6` major releases. A release must not be merged or distributed until the `Windows tests` job passes and the separate real-install verification described below succeeds on the release machine.

Before delivering a candidate EXE, run the guarded real GUI installation check. This step stops and replaces the current local DSH installation, so the explicit confirmation switch is required:

```powershell
$managerExe = (Resolve-Path -LiteralPath '.\HarnessControl\bin\Release\verified-publish\DeepSeek Harness 控制台.exe').Path
pwsh -NoProfile -File .\tests\Verify-RealInstall.ps1 -ManagerExe $managerExe -ConfirmRealInstall
```

The real-install check is intentionally not run on a shared GitHub runner. It must verify HTTP 200, a non-busy final status, and enabled Close and Update buttons before the candidate EXE is copied to the download directory.

Run the same check a second time with the installed desktop `DeepSeek Harness 控制台.exe` as `-ManagerExe`. This covers in-place reinstallation: the installer must preserve the manager EXE that is currently running, finish the DSH replacement, and restore the Close and Update buttons. If a cancelled or timed-out PowerShell process cannot be terminated, the manager keeps every operation except Close disabled until that exact process tree is confirmed stopped.

## Safety model

The updater treats a successful homepage response as necessary but insufficient. It also checks the client JavaScript for each SSS plugin explicitly enabled by the active Web profile. It discovers the highest published Harness release instead of relying only on the npm `latest` tag, so prereleases such as `rc.1` are not missed. If an update cannot pass the checks, it restores the saved `package.json`, lock files, and workspace configuration, reinstalls the previous dependency graph, and starts the recovered service.

The manager and installer require PowerShell 7 and no longer fall back to Windows PowerShell 5.1. This avoids UTF-8 script and JSON parsing failures on Windows.

An existing desktop controller is overwritten only after its product metadata identifies it as this manager. Redirecting symbolic-link targets are rejected; non-redirecting file-provider metadata may remain on redirected or synchronized desktop folders.

New installations and updates query the complete published `@deepseek-ai/dsh` version list and select the highest supported stable or `rc.N` version instead of relying on the npm `latest` tag. The selected DSH package supplies the official Web UI. If the version list cannot be queried or parsed, the operation stops with an explicit error rather than silently falling back to an older pinned release.

## Notes

This is a local-management project, not the official DeepSeek Harness distribution. Release payloads are generated from the project and are intentionally not versioned in Git.
