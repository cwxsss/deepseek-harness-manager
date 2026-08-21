# Install Latest Published DSH Design

## Goal

New installations must resolve and install the highest published `@deepseek-ai/dsh` semantic version at installation time, including `rc.N` prereleases. The installer must no longer pin `0.1.1-rc.1`.

## Options considered

1. Use the npm `latest` dist-tag. This is simple, but the tag can lag behind an RC published under `next`, so it does not satisfy “highest published version”.
2. Use the GitHub latest Release. This is authoritative for release announcements, but a GitHub release can exist before the npm package is available, while installation ultimately consumes npm.
3. Query the npm package version list and choose the highest supported semantic version. This matches the existing updater and is the selected approach.

## Design

Add one shared PowerShell helper under `Installer/payload/launcher` with two responsibilities:

- Select the highest version from a supplied list using numeric `major.minor.patch`, with a stable release ranked above an `rc.N` of the same base version.
- Query `pnpm view <package> versions --json`, validate its output, and pass the returned list to the pure selector.

The installer will call this helper after Node/Corepack is ready, log the selected DSH version, and install `@deepseek-ai/dsh@<resolved-version>`. The updater will use the same helper so installation and update cannot drift to different ordering rules.

Supported versions are `X.Y.Z` and `X.Y.Z-rc.N`. Unknown prerelease formats are ignored rather than guessed. If no supported version can be resolved, installation stops with a clear error and does not silently fall back to an old pinned version.

## Data flow

1. Installer prepares Node.js and Corepack.
2. Shared helper runs `corepack pnpm --color never view @deepseek-ai/dsh versions --json`.
3. JSON is parsed into a version list.
4. The pure selector returns the highest supported version.
5. Installer logs `准备安装 Harness 最新版本：<version>`.
6. Installer runs `pnpm add @deepseek-ai/dsh@<version>` and continues its existing rebuild, Web profile, startup, and health checks.

## Error handling

- A nonzero package-query exit code is a hard failure with the package name in the message.
- Invalid JSON is a hard failure with the parse error included.
- An empty or unsupported version list is a hard failure.
- Existing transactional updater rollback behavior remains unchanged.
- Node download, plugin selection, start/stop behavior, and the two bundled SSS plugin versions are outside this change.

## Tests

Behavioral PowerShell tests will import the real shared helper and verify:

- `0.1.1-rc.1` is selected over `0.1.0-rc.8`.
- `0.1.1` is selected over `0.1.1-rc.9`.
- RC sequence numbers are compared numerically (`rc.10` over `rc.9`).
- Unsupported entries are ignored.
- No supported version produces an explicit failure.

The existing installer regression checks, PowerShell parsing, single-file publish, and Git status checks remain required before delivery.

## Documentation and delivery

README and `Installer/说明.txt` will state that new installations resolve the highest published official DSH version at run time. The release artifact remains one self-contained Windows x64 EXE.
