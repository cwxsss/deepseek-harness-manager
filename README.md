# DeepSeek Harness Manager

A Windows desktop manager for a local DeepSeek Harness installation. It provides a compact console for starting, stopping, and safely updating Harness.

## Features

- Start and stop the local Harness service on `127.0.0.1:3080`.
- Check for and install Harness and Web UI updates.
- Create a timestamped profile snapshot before an update.
- Validate the homepage and enabled top-level plugin scripts after an update.
- Automatically restore the previous profile state when an update fails validation.
- Refuse an update when the Web UI aggregate contains an undeclared client-plugin junction, preventing stale plugin links from breaking the UI.

## Project layout

- `HarnessControl/` — Windows Forms control application.
- `Installer/` — portable installation and repair scripts, launcher templates, and the bundled billing/reasoning plugins.

The repository deliberately excludes generated binaries, Node.js runtimes, dependency folders, local profiles, logs, and personal configuration.

## Build

Requirements: Windows and the .NET 10 SDK.

```powershell
dotnet build .\HarnessControl\HarnessControl.csproj -c Release
```

## Safety model

The updater treats a successful homepage response as necessary but insufficient. It also checks the client JavaScript for each plugin explicitly enabled by the active Web profile. If an update cannot pass the checks, it restores the saved `package.json`, lock files, and workspace configuration, reinstalls the previous dependency graph, and starts the recovered service.

## Notes

This is a local-management project, not the official DeepSeek Harness distribution. The portable installer source expects release payloads (the built control executable and Node.js runtime archive) to be assembled separately; those large generated artifacts are intentionally not versioned here.
