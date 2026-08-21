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
dotnet build .\HarnessControl\HarnessControl.csproj -c Release
pwsh -NoProfile -File .\tests\Verify-Installer.ps1
```

## Safety model

The updater treats a successful homepage response as necessary but insufficient. It also checks the client JavaScript for each SSS plugin explicitly enabled by the active Web profile. It discovers the highest published Harness release instead of relying only on the npm `latest` tag, so prereleases such as `rc.1` are not missed. If an update cannot pass the checks, it restores the saved `package.json`, lock files, and workspace configuration, reinstalls the previous dependency graph, and starts the recovered service.

The manager and installer require PowerShell 7 and no longer fall back to Windows PowerShell 5.1. This avoids UTF-8 script and JSON parsing failures on Windows.

New installations use the official Harness baseline `0.1.1-rc.1`. The updater still discovers the highest published Harness and Web UI release, including RC versions, at update time.

## Notes

This is a local-management project, not the official DeepSeek Harness distribution. Release payloads are generated from the project and are intentionally not versioned in Git.
