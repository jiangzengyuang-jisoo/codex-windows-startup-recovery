# Codex Windows Startup Recovery

[中文](README.md)

An unofficial, on-demand workaround for the Windows Codex desktop app getting stuck on its startup spinner. Leave the desktop alive and restart only its own initial app-server so the app can replace the backend.

**This is a temporary workaround, not a permanent fix.** The author confirmed both manual recovery and the original shortcut working locally. Other machines, versions and repeated future launches are not guaranteed.

Known affected MSIX: `OpenAI.Codex_26.924.2738.0_x64__2p2nqsd0c76g0`. After manual recovery, an actual `Get-Location` tool call succeeded. Healthy sandbox setup (`errors=[]`) does not prove startup is fixed.

## Shortcut setup

Requires Windows, a registered production Codex desktop app and an existing PowerShell 7. No administrator launch is needed. Extract the complete repository to a permanent folder and review its source. In a separate PowerShell 7 window, run:

```powershell
.\Install-Shortcut.ps1
```

The installer only creates a desktop shortcut. It does not launch Codex, stop processes, overwrite existing shortcuts, install software or change execution policy. An explicit existing shell can be selected:

```powershell
.\Install-Shortcut.ps1 -PowerShellPath 'C:\Program Files\PowerShell\7\pwsh.exe'
```

Downloaded scripts may carry Windows' internet-origin marking. If blocked, review the source and origin first; only unblock specific trusted files through their Properties if your policy permits it. Do not bypass execution policy or organizational restrictions. No automatic unblocking is included.

Wait for all tasks to finish, exit Codex normally, then use the new shortcut. **Do not submit tasks until the recovery-complete notice and a usable UI appear.** Progress notices are currently in Chinese. A completion notice means no further process termination will occur, not that the UI has been verified ready.

## Behavior and limits

- An existing desktop is activated only; no backend is stopped.
- A fresh instance uses normal `IApplicationActivationManager` activation of `OpenAI.Codex_2p2nqsd0c76g0!App`, without debug flags.
- The activation PID, prelaunch snapshot, creation time, Windows session, package family and executable path are checked. Only the unique direct `codex.exe app-server` child is eligible, with its hash checked against the bundled backend.
- Wait at least 35 seconds after activation and 3 seconds after selecting the backend, require a renderer, then revalidate. Termination uses a held native process handle rather than retargeting a PID that could be reused.
- At most one termination is attempted. Wait for the same desktop to create a replacement and observe it for 5 seconds. Ambiguous identity, identity changes, timeout or access failure aborts without broadening matching or retrying another target.
- A per-user/session mutex suppresses repeated double-clicks. The launcher exits after its bounded workflow and completion notice.
- **This is not a spinner detector:** each eligible fresh launch attempts one recovery. Switch back to the original entry when the app is fixed.
- No service, startup entry, scheduled task, persistent monitor, debug injection, package patch, Beta installation or user-data reset.

The three core source files are preserved from the locally tested shortcut. This public package adds a portable shortcut creator. The original 28 static/simulated checks passed without activating Codex or terminating a real process. Cross-machine behavior and all races remain unverified.

## Manual alternative

While the desktop is stuck at startup, keep its window open and ensure **no task is running**. Use a separate PowerShell window to run [Manual-Recovery.ps1](Manual-Recovery.ps1), or paste its complete `& { ... }` block. Never execute it as a tool from an active Codex task.

The short manual command uses a process snapshot and has fewer protections than the guarded launcher. Do not change it to kill every `codex.exe` process.

## Testing and removal

```powershell
pwsh -NoProfile -File .\tests\Test-Launcher.ps1
```

Tests parse the entry point, compile the helper and exercise pure identity checks with fake processes. They do not run the launcher.

After actual use, `last-run.json` stores local status, timestamps and process IDs; error messages may contain private paths. Review and redact before sharing. No telemetry is sent and the file is git-ignored.

To remove: wait for the progress window to finish, then delete the desktop shortcut and extracted folder. No system configuration needs reverting. Keep the extracted folder at its original location while using the shortcut.

## Background

[Issue #48466](https://github.com/openai/codex/issues/48466) · [Workaround comment](https://github.com/openai/codex/issues/48466#issuecomment-5868057327) · [Related #48463](https://github.com/openai/codex/issues/48463)

These reports are diagnostic leads, not proof of a root cause or official fix. This project is not affiliated with OpenAI and contains no OpenAI executable or icon assets.

[MIT License](LICENSE).

## One real test of the 35-second version

On 2026-09-28, after the user exited and relaunched, the control component became ready before the one-time backend restart. The configuration refreshed to a live connection, an actual window-list operation succeeded, and browser control opened GitHub. The previous run had a stale connection with no server. This supports keeping the 35-second delay as a workaround, but does not establish timing as the sole cause or guarantee future launches.
