# DeepSeek Harness Manager Operation Completion Design

## Goal

Prevent install, start, update, and cancellation operations from leaving the manager permanently in a busy state. An operation must finish when its direct PowerShell process exits, even when a long-running Harness child process keeps inherited output handles open. No release is allowed until automated Windows tests and one real local installation prove that the UI leaves the busy state and restores the correct buttons.

## Confirmed failure

The current failure has two independent causes:

1. `Install-DeepSeekHarness.ps1` calls `Write-InstallLog (if (...) { ... })`. PowerShell treats `if` as a command in that expression position, so the script reports failure after Harness has already started and passed HTTP health checks.
2. `ExecutePowerShellAsync` starts asynchronous output reads and then calls `WaitForExitAsync`. The installer PowerShell process exits, but the long-running Node service can keep an inherited output pipe open. The manager therefore never returns from the process runner, never reaches `RunExclusiveAsync` cleanup, and leaves the UI in `正在安装`.

The existing regression fixture verifies that a launcher script itself returns promptly. It does not execute the manager's redirected-process path and therefore cannot detect the retained-output-pipe failure.

## Selected approach

Use a dedicated, independently testable process runner and a small operation-state model.

- The direct PowerShell process handle is the authoritative completion signal.
- Standard output and standard error remain visible in real time, but output draining is bounded and cannot keep the operation busy indefinitely after the direct process exits.
- Exit code, timeout, and cancellation are returned as explicit operation results.
- UI cleanup remains in one guaranteed `finally` path. Success, failure, exception, timeout, and cancellation must all clear the active operation and refresh button state.
- Starting Harness remains successful only after the launcher reports success or the existing HTTP-health shortcut confirms HTTP 200. The process runner must not terminate the long-running Node service when releasing the completed launcher.

## Alternatives rejected

### Result file polling

The installer could write a completion JSON file and the manager could poll it. This adds stale-file handling, atomic-write rules, and another source of truth while the direct process already supplies an exit code.

### Timeout-only workaround

Adding a timeout to the current output wait would eventually recover the UI but would still show a completed installation as busy until the timeout. It treats the symptom rather than the retained-pipe cause.

## Components

### Installer completion tail

Replace the invalid inline `if` expression with ordinary statement-form branching. Both `NoLaunch` and launched-success paths write their final status and then save the installation report without throwing.

### Process runner

Move PowerShell process execution out of `MainForm` into a class that accepts a script path, arguments, action name, output callback, timeout, and cancellation token. It returns a typed result containing the exit code and completion reason.

The runner starts asynchronous output capture, waits for the direct process to exit, reads the exit code, performs only a bounded output-drain phase, detaches output handlers, and returns. Cancellation terminates only the intended direct operation tree; a successfully detached Harness service is preserved.

### Operation state

Represent idle, running, and stopping states independently from WinForms controls. `MainForm` renders buttons from this state:

- Running install/update/start: only Close is enabled.
- Stopping: all buttons are temporarily disabled.
- Idle with a complete running Harness: Reinstall, Close, Update, and Uninstall are enabled; Start is disabled.
- Idle with an incomplete installation: Repair installation and Uninstall remain enabled, while Start and Update are disabled.
- Idle without Harness: only Install is enabled; no stale busy flag remains.

The final UI state is recalculated from installation presence and HTTP health after every operation result.

## Error handling

- Installer script failures retain their nonzero exit code and desktop report.
- A retained child output handle produces a diagnostic message after bounded drain, not a stuck UI.
- Timeout and cancellation terminate the direct operation, report the reason, and always restore idle controls after status refresh.
- Failure to refresh HTTP status must not bypass operation cleanup.
- Existing safe uninstall target boundaries remain unchanged.
- Reinstallation may overwrite an older desktop controller only when Windows product metadata identifies it as `DeepSeek Harness 控制台`; an unrelated same-name file still blocks installation.

## Automated tests

Tests must execute real production process-runner and state-model code. They must fail against the current implementation before production changes are made.

1. A fixture launches a child process that outlives its PowerShell parent while retaining an inherited output handle. Assert that the manager runner returns within five seconds and preserves the child until test cleanup.
2. A fixture exits with a nonzero code. Assert that the code is propagated and the state model returns to idle.
3. A long-running fixture is cancelled. Assert that cancellation finishes within five seconds and the state model returns to idle.
4. Success, failure, exception, timeout, and cancellation state tests assert the resulting install, start, close, update, and uninstall availability.
5. Installer behavior tests exercise both final status branches so the invalid `if` form cannot recur.
6. Existing version-resolution, installer regression, PowerShell parsing, build, and single-file EXE checks remain required.
7. A cancellation-then-stop concurrency test proves that the stop operation waits for the active operation gate and that the stopping state takes precedence until shutdown finishes.
8. Installer target tests accept verified prior manager metadata and reject unrelated or malformed same-name desktop files.

## Release gates

Local and GitHub Actions Windows checks are both mandatory:

1. PowerShell 7 script and installer tests.
2. .NET process-lifecycle and operation-state tests.
3. Release build with zero errors.
4. Single-file Windows x64 publish and artifact-shape verification.
5. On the local machine, one real installation using the newly built EXE: verify the selected latest DSH version, HTTP 200, the UI no longer shows `正在安装`, and Close and Update are enabled after completion.

Only after every gate passes may the change be committed to the implementation branch, merged into `main`, pushed, and delivered as a new EXE. A failed gate stops publication; it is not waived by a successful HTTP health check alone.

## Scope

This change covers installer finalization, manager process lifecycle, UI operation-state recovery, automated regression coverage, and release gating. It does not alter plugin selection, DSH version-selection policy, install locations, uninstall targets, or the single-EXE delivery requirement.
