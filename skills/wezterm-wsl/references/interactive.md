# Interactive terminal operations

Use these when a program needs a real terminal or interactive stdin. `$helper` is the skill's `scripts/Invoke-WezTerm.ps1` path. With an attached session, the helper reuses its endpoint:

```powershell
& $helper -Action Read -MaxChars 2000
$inputText = @'
python3
'@
& $helper -Action Send -Text $inputText -Enter
& $helper -Action Read
```

Read before sending to an existing pane. Identify the foreground program and prompt; do not assume Bash from the window title or Windows-side cwd. Send uses UTF-8 paste mode; Enter is a separate carriage return. Paste semantics depend on the receiving program. Without Enter, text remains unsubmitted at a typical Bash prompt with bracketed paste enabled. Send delivery is not completion proof.

Use `-TextFile` instead of `-Text` for a literal UTF-8 input file. Preserve Bash `$variables` with single-quoted PowerShell strings/here-strings. Avoid ad-hoc cross-shell interpolation. A Read is bounded screen text including echoes, prompts, wrapping, and limited history; it is not a clean output stream. `-StartLine -120` includes more scrollback; `-MaxChars` still bounds the response.

```powershell
& $helper -Action Key -Key Enter
# Only when intentionally interrupting the foreground program:
& $helper -Action Key -Key CtrlC
```

CtrlD can close the shell; Escape is also supported. No automatic interrupts or retries. After an interrupted Run bypasses its completion marker, inspect the pane, ensure the job has stopped and Bash is idle, then reattach using `-ResetSession` to clear the unfinished-job record. Do not issue Run while a REPL, pager, editor, or password prompt owns the pane.

Before attaching, pass explicit `-SocketPath` and `-PaneId` to Read/Send/Key. Once attached, omit both or supply the same `-Session`/`-StateRoot` used by Attach. A GUI restart requires rediscovery, not reuse of the previous socket filename.

## Open a dedicated task window

Find the actual distribution with `wsl.exe --list --verbose`; decode UTF-16LE if redirected output contains NULs. WezTerm discovery checks PATH and standard install directories; `-WezTermPath` supports another installation. List returns the resolved `wezterm_path` even with no connected panes.

When a visible shared terminal is appropriate:

```powershell
$wezGui = Join-Path (Split-Path $wezExe) 'wezterm-gui.exe'
Start-Process -FilePath $wezGui -ArgumentList @(
  'start', '--always-new-process', '--workspace', 'codex-wsl',
  '--', 'wsl.exe', '-d', $distro, '--cd', '~'
)
& $helper -Action List
```

Use the returned executable path and the user's selected distro. Inspect startup output, then attach to the idle Bash prompt. Do not silently install software or answer first-run setup/password prompts. Keep a requested shared terminal available after finishing. Do not delete socket files, edit shell profiles, or start a mux daemon to fix endpoint discovery; the helper supplies an absolute `WEZTERM_UNIX_SOCKET` only to its subprocess.

## Official interface references

- [CLI and endpoint targeting](https://wezterm.org/cli/cli/index.html)
- [Sending text](https://wezterm.org/cli/cli/send-text.html) and [capturing output](https://wezterm.org/cli/cli/get-text.html)
- [Multiplexing and session lifetime](https://wezterm.org/multiplexing.html)
