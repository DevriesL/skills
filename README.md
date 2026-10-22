# Skills

[简体中文](README.zh-CN.md)

Practical agent skills from my everyday workflows. Each skill lives in its own directory and can be installed independently. This collection will grow beyond the initial WSL workflow.

## Available skills

| Skill | Purpose | Requirements |
| --- | --- | --- |
| [wezterm-wsl](skills/wezterm-wsl/SKILL.md) | Operate persistent WSL shells from Windows through WezTerm, with compact output and completion notifications. | Windows, PowerShell 7+, WezTerm, WSL with Bash/coreutils; Python 3 for file operations; ripgrep for grep/glob |

`wezterm-wsl` intentionally becomes the default workflow for WSL operations when available to the agent, even if you do not explicitly name it. Explicit user choices take precedence. General WSL questions do not open a terminal, and Windows-side WSL management can use the appropriate Windows tools.

## Install one skill

With Node.js/npm available, list the collection or install a specific skill using the [skills CLI](https://github.com/vercel-labs/skills):

```bash
npx skills add DevriesL/skills --list
npx skills add DevriesL/skills --skill wezterm-wsl -a codex -g
```

Run the installer in the environment where your agent runs. For an agent running on Windows, run it from Windows so the skill is available there; the helper then controls WSL through WezTerm. Omit `-g` for a project installation. The skill has been exercised with Codex on Windows; installing it for another agent does not establish that agent's compatibility.

Alternatively, ask Codex to use its skill installer:

```text
Use $skill-installer to install skills/wezterm-wsl from DevriesL/skills.
```

Start a new agent session after installation. You can then ask, for example: "Use WSL to inspect the current directory and Git status." The agent follows the skill's discovery and attachment workflow. WezTerm and your WSL distribution must already be installed.

## Install the collection as a Codex plugin

This repository also provides a marketplace named `devries-skills` and a plugin with the same name. The plugin bundles all skills under `skills/`; use the individual installation above if you only want selected skills. Choose one installation method to avoid duplicate skills.

With a Codex CLI that supports plugin marketplaces:

```bash
codex plugin marketplace add DevriesL/skills
codex plugin add devries-skills@devries-skills
```

Start a new session to load the installed skills. Marketplace support depends on your Codex version and surface; the individual skill installation remains an alternative. This is a repository marketplace, not a listing in the OpenAI public plugin directory. See the [official plugin documentation](https://developers.openai.com/plugins/build/plugins).

## Short command and file API

After attaching a WezTerm session as described in the [skill instructions](skills/wezterm-wsl/SKILL.md), run the installed `scripts/wsl.ps1 init` once to create a task-local `work/wsl.ps1` launcher. It keeps the session binding without changing your PATH or shell profile.

```powershell
& .\work\wsl.ps1 exec 'git status --short' -Cwd /home/user/project
& .\work\wsl.ps1 cd /home/user/project
& .\work\wsl.ps1 ls -All
& .\work\wsl.ps1 glob '**/*.py' -Root src
& .\work\wsl.ps1 grep 'TODO|FIXME' -Root src -Glob '*.py' -Limit 30
& .\work\wsl.ps1 read src/app.py -From 1 -Lines 80
& .\work\wsl.ps1 write notes.txt -Content 'Hello'
& .\work\wsl.ps1 edit notes.txt -Old 'Hello' -New 'Hello world'
& .\work\wsl.ps1 mv notes.txt -To archive/notes.txt -Parents
```

`grep` searches contents and returns paths, line numbers, and matching text; `glob` finds files. Both stop at the requested result/character limit and use ripgrep in WSL (`rg` on PATH or at `~/.local/bin/rg`). `-Root` scopes the search, `-Glob` filters files, and grep supports `-Literal`/`-IgnoreCase`. See the [search reference](skills/wezterm-wsl/references/files.md#searching) for ignore rules and explicit glob behavior.

`exec` still supports arbitrary noninteractive Bash commands. The file operations run directly in WSL, preserve existing Linux modes and consistent CRLF formatting, and return bounded readable results. `write` and `mv` refuse overwrite by default; `edit` checks unique matches. Supply `-ExpectedHash` from `read` to reject stale edits. Use `-Json` when consuming results in code. See the [file API reference](skills/wezterm-wsl/references/files.md) for details.

## How wezterm-wsl works

The Windows PowerShell helper attaches to a chosen idle Bash prompt in WezTerm. Commands run in that same shell, preserving working directory, variables, and functions. Normal runs return compact JSON with the exit code, current directory, and separate stdout/stderr while keeping output visible in the terminal.

Long-running commands return a job ID. `Wait` reads only new output and waits for a completion file using filesystem notifications with a local-file fallback, without repeatedly capturing the terminal. Large output is bounded in responses and retained in full logs.

`scripts/run-driver.bash` is a per-job template: it runs the command in the selected Bash shell, copies output through `tee`, and writes the completion marker after the log writers finish. It needs no background service or shell-profile changes.

The session lasts while the WezTerm pane and WSL shell remain alive. Interactive programs use the skill's separate [interactive workflow](skills/wezterm-wsl/references/interactive.md). Commands, logs, and session state are stored in `work/wezterm-wsl` under the Windows working directory by default, so do not place credentials in command text or commit runtime state.

## Add another skill

1. Create `skills/<skill-name>/SKILL.md` with YAML `name` and `description` fields and focused instructions.
2. Include `scripts/`, `references/`, `assets/`, or `agents/` only when the skill needs them. Keep supporting paths relative and discover machine-specific paths at runtime.
3. Document requirements, test the intended workflow, and add a row to both README tables.
4. Bump `plugin.json`'s version when releasing changes to the collection. The plugin discovers skills under `skills/`, so adding another skill does not require another marketplace entry.

```text
skills/
  wezterm-wsl/
    SKILL.md
    agents/
    references/
    scripts/
  another-skill/
    SKILL.md
```

## Validation

Run the file-operation tests inside Linux/WSL:

```bash
python3 -m unittest discover -s tests -v
```

The Windows integration test requires PowerShell 7, WezTerm, and an already attached session. From a Windows checkout, run `tests/test_bridge.ps1 -Entry PATH_TO_INSTALLED_SCRIPTS/wsl.ps1`, using the same `-StateRoot` as Attach. It tests real transport, shell state, file operations, and incremental waits in an isolated temporary WSL directory.

## License

[MIT](LICENSE)
