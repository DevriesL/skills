---
name: wezterm-wsl
description: "Default workflow for WSL operations from Windows, even when WezTerm or this skill is not explicitly named. Run commands in persistent WSL sessions through WezTerm with compact results, exit codes, and event-driven waiting."
---

# WezTerm WSL

Use this skill by default when executing work in WSL from Windows, without requiring the user to name it each time. Honor an explicit request for another method. If the workflow is unavailable or an operation requires Windows-side WSL management, explain briefly and use an appropriate alternative within the task's existing authorization. Purely explanatory WSL questions do not require starting a terminal session.

Use `scripts/Invoke-WezTerm.ps1` with PowerShell 7. **Default to Run for noninteractive Bash commands.** It sources a command file in the existing shell, captures separate stdout/stderr, and returns compact JSON when complete. It does not scrape the screen or repeatedly call WezTerm to detect completion.

## Once per task: attach

Set `$helper` to this skill's absolute `scripts/Invoke-WezTerm.ps1` path.

```powershell
& $helper -Action List
& $helper -Action Read -SocketPath $socket -PaneId $pane -MaxChars 1500
& $helper -Action Attach -SocketPath $socket -PaneId $pane
```

Choose the user's intended **idle Bash prompt inside WSL**, based on List's workspace/title and a fresh Read. Prefer a dedicated task pane. Do not assume the focused pane or pane 0, or send a probe into an unknown foreground program. To create a window or operate an interactive program, read [references/interactive.md](references/interactive.md).

Attach caches the exact socket, pane, GUI start time, and Bash PID. The helper handles the Windows relative-socket discovery issue by passing the absolute socket path to each CLI subprocess. No global configuration changes or fixed PIDs are needed.

State and logs live under the Windows working directory's `work/wezterm-wsl`. Keep that working directory stable, or pass the same absolute `-StateRoot` each time. Use `-Session name` for another binding. The default maps local drives to `/mnt/drive`; for custom WSL mounts, supply the corresponding `-LinuxStateRoot` when attaching. Attach verifies access to that directory.

## Normal commands: one call

```powershell
& $helper -Text 'pwd; git status --short'
```

`Run` is the default action. Use a literal single-quoted PowerShell here-string for multiline commands, or `-TextFile` for a UTF-8 file. The helper normalizes CRLF and passes only a short, quoted source command to the terminal. Shell variables, functions, and `cd` persist between runs.

Read the returned `status`, `exit_code`, `cwd`, `stdout`, and `stderr`; empty streams are omitted. **Do not follow a successful Run with Read, List, or another verification poll.** A completed nonzero `exit_code` is a command failure even though the helper returned JSON successfully.

Run waits up to 20 seconds by default (`-WaitSeconds 0..25`). Use `exec_command` with `yield_time_ms: 30000` for the default wait to avoid an unnecessary outer process poll.

## Longer jobs: resume by ID

```powershell
& $helper -Text 'make test' -WaitSeconds 1
& $helper -Action Wait -Job $job -WaitSeconds 20
```

A `running` result means completion has not yet been observed; it does not prove the shell is still making progress. Continue with Wait, not another Run. Omit `-Job` to wait for this session's latest job. Wait uses a filesystem completion notification with a two-second local-file fallback; it makes **no WezTerm calls or terminal captures**. Each result contains only newly read output, using saved byte offsets. Prefer bounded waits over repeated immediate checks; provide progress updates as needed.

Output is bounded to 4000 characters **per stream** (`-MaxChars` overrides). If truncated, the response provides `full_output_directory`; inspect relevant portions of those files rather than dumping everything. Logs and command files remain in the task folder for recovery. Do not put passwords or tokens into command text. Session locks and unfinished-job checks reject overlapping Run calls.

For `delivery_unknown`, use Wait or Read before retrying: the command may already have executed. If a session is lost, rediscover and attach. `Attach -ResetSession` only forgets an unfinished job; use it after inspecting the terminal and resolving the old job. It does not cancel anything. Never automatically resubmit an ambiguous command.

## Execution boundaries

Run requires Bash, `tee`, and a Windows directory writable through WSL. It executes in the existing shell with stdin closed and output routed through pipes while also displayed in WezTerm. Use the interactive workflow for password prompts, sudo authentication, REPLs, and full-screen applications. For `exit`, `exec`, shell-wide `set -e`, or other changes that can bypass the completion wrapper, use a child shell when appropriate or the interactive workflow. Background processes should redirect their own stdin/stdout/stderr, otherwise inherited pipes can delay completion.

The GUI pane must remain alive. Closing it, stopping WSL, or rebooting does not preserve this session. User commands still determine their own side effects; this skill grants no additional filesystem, network, credential, or external-action permissions. Some Windows sandboxes cannot reach the local WezTerm socket. In Codex, use an authorized `exec_command` call with `sandbox_permissions: "require_escalated"` when that boundary prevents access; other hosts should use their corresponding approval mechanism. Scope approval to the actual command, without repeatedly probing a known-inaccessible socket or treating terminal input as a permission bypass.

`-Metrics` adds CLI/capture/completion-check counts for debugging; omit it during ordinary work. The raw List, Read, Send, and Key interfaces remain available for interactive tasks; load their reference only when needed.
