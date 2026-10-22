---
name: wezterm-wsl
description: "Default workflow for WSL operations from Windows, even when WezTerm or this skill is not explicitly named. Run commands and directly list, read, write, edit, and move Linux files through a persistent WezTerm session with compact results and event-driven waiting."
---

# WezTerm WSL

Use this skill by default for WSL operations from Windows without requiring the user to name it. Honor explicit alternatives. For Windows-side WSL management or an unavailable workflow, explain briefly and use an appropriate alternative within existing authorization. Explanatory questions alone do not require a terminal.

Use PowerShell 7. `scripts/wsl.ps1` provides short command and file operations; `scripts/Invoke-WezTerm.ps1` remains the low-level terminal/JSON interface. Commands use the existing Bash shell, preserving its directory, variables, and functions. File operations require Python 3 in WSL; `mv` uses GNU coreutils.

## Once per task: attach and create a short launcher

Set `$helper` and `$entry` to this skill's absolute `scripts/Invoke-WezTerm.ps1` and `scripts/wsl.ps1` paths. Discover the intended pane, inspect its idle Bash prompt, then attach:

```powershell
& $helper -Action List
& $helper -Action Read -SocketPath $socket -PaneId $pane -MaxChars 1500
& $helper -Action Attach -SocketPath $socket -PaneId $pane
& $entry init
```

Choose an idle **Bash prompt inside WSL**, not merely a familiar title or pane number. Do not send probes into an unknown foreground program. Prefer a dedicated task pane. Read [interactive.md](references/interactive.md) to create a window or operate an interactive program.

`init` creates `work/wsl.ps1` in the Windows task directory, with the skill path, session, and absolute state directory bound into it. It changes no global PATH, profile, or execution policy and refuses to overwrite an unrelated file. Windows shell variables do not persist between tool calls; use the generated launcher in subsequent calls instead of repeatedly declaring long helper paths. Reuse a valid attachment within the task; after user activity or an interruption, inspect the pane before sending more input.

Attach caches the socket, GUI start time, and Bash PID. State lives in `work/wezterm-wsl`; use the same `-Session` and `-StateRoot` for Attach and init when overriding them. Local drives map to `/mnt/drive` by default; supply `-LinuxStateRoot` on Attach for custom WSL mounts. The helper passes the absolute socket only to its CLI subprocesses.

## Everyday operations

```powershell
& .\work\wsl.ps1 exec 'git status --short' -Cwd /home/user/project
& .\work\wsl.ps1 cd /home/user/project
& .\work\wsl.ps1 ls -All
& .\work\wsl.ps1 read src/app.py -From 1 -Lines 80
& .\work\wsl.ps1 write notes.txt -Content 'Hello'
& .\work\wsl.ps1 edit notes.txt -Old 'Hello' -New 'Hello world'
& .\work\wsl.ps1 mv notes.txt -To archive/notes.txt -Parents
```

Paths are Linux paths relative to the persistent shell directory. `cd` and `-Cwd` persist; a failed `-Cwd` prevents the operation from running. File contents travel as UTF-8 JSON, not shell-interpolated strings. Prefer these file operations over staging a second working copy on Windows. `read` here reads a file; the low-level helper's `-Action Read` captures the terminal screen.

`write` creates a file by default; replacing one requires `-ExpectedHash` from a previous read or explicit `-Overwrite`. `edit` performs an exact unique text replacement; `-All` explicitly allows multiple matches. Use `-ExpectedHash` when modifying a file you have read. `mv` uses an exact destination and refuses overwrite by default. Read [files.md](references/files.md) for multiline content, bounds, newline/mode preservation, and JSON requests.

Results default to concise readable text: inspect `status` and `exit`. The short entry sets PowerShell LASTEXITCODE to the command exit and signals failures to its caller; an outer PowerShell command host may normalize a nonzero process status to 1, so inspect exit for the exact code. Running jobs return zero with a job ID. The low-level helper reports command exits inside JSON. Use `-Json` only for programmatic consumption. With `functions.exec`, display `text(result.output)` rather than serializing the whole native tool result again. **Do not follow completed commands with terminal Read or List just to confirm completion.**

## Long jobs and output

```powershell
& .\work\wsl.ps1 exec 'make test' -WaitSeconds 1
& .\work\wsl.ps1 wait JOB_ID -WaitSeconds 20
```

Wait defaults to 20 seconds (range 0..25). With `exec_command`, use `yield_time_ms: 30000` for the default wait. A running result gives a job ID; continue with `wait`, not another `exec`. Omit the ID to wait for the latest job. Wait uses completion-file notifications with a two-second local-file fallback and makes no WezTerm calls. It returns only new output or an unreported structured result. Prefer bounded waits to repeated immediate checks.

Shell output is bounded to 4000 characters per stream (`-MaxChars` overrides); truncated results point to full logs. File reads and lists have their own bounds described in the file reference. Commands, requests, and logs remain in the task state directory; avoid credentials in command text or file payloads and do not commit runtime state. Locks and unfinished-job checks reject overlapping runs.

For `delivery_unknown`, wait or inspect the terminal before retrying: execution may already have occurred. `running` does not prove progress. If a session is lost, inspect and reattach. `Attach -ResetSession` only forgets an unfinished job; resolve the old job first. It does not cancel it. Never automatically resubmit an ambiguous mutation.

## Execution boundaries

The bridge requires Bash, `tee`, and a Windows directory writable through WSL. Noninteractive runs have stdin closed and output routed through pipes while remaining visible in WezTerm. Use the [interactive workflow](references/interactive.md) for password prompts, sudo authentication, REPLs, and full-screen programs. Use a child shell or interactive workflow for `exit`, `exec`, shell-wide `set -e`, or other changes that can bypass completion. Background processes must redirect their own streams to avoid holding output pipes open.

Closing the GUI pane, stopping WSL, or rebooting ends the session. The skill grants no additional filesystem, network, credential, or external-action permissions. If a Windows sandbox cannot reach the WezTerm socket, use the host's approval mechanism for the actual operation (in Codex, an authorized `exec_command` with `sandbox_permissions: "require_escalated"`). Do not repeatedly probe a known-inaccessible socket or use terminal input to bypass permissions.

`-Metrics` exposes CLI/capture/completion-check counts for diagnostics; omit it normally. The original List, Read, Send, Key, Attach, Run, and Wait actions remain available.
