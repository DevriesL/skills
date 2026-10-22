# Direct WSL file operations

Use the task-local launcher created by `scripts/wsl.ps1 init`. The primary interfaces are:

| Operation | Parameters | Result |
| --- | --- | --- |
| `cd PATH` | Linux directory, including `~` or `~/...` | Persistent Bash cwd |
| `ls [PATH]` | `-All`, `-Limit` (default 100, max 1000), `-MaxChars` | Sorted names, `/` for directories, `@` for symlinks, omitted count |
| `grep PATTERN` | `-Root` (default `.`; directory or file), `-Glob` (string array), `-Literal`, `-IgnoreCase`, `-All`, `-Limit`, `-MaxChars` | Relative path, 1-based line number, matching line text |
| `glob PATTERN` | `-Root` (default `.`; directory), optional `-Glob` exclusions/filters, `-All`, `-Limit`, `-MaxChars` | Matching relative file paths |
| `read PATH` | `-From` (1-based), `-Lines` (default 120), `-MaxChars` (default 4000) | Numbered text, total lines, SHA-256 of the entire file |
| `write PATH` | `-Content` or Windows `-TextFile`; `-Parents`; `-ExpectedHash` or `-Overwrite` for replacement | Bytes written and new hash |
| `edit PATH` | `-Old`, `-New`, optional `-All` and `-ExpectedHash` | Exact replacement count and new hash |
| `mv PATH` | `-To` exact destination, optional `-Parents`, `-Overwrite`, `-ExpectedHash` for regular files | Source and destination |
| `exec COMMAND` | Optional `-Cwd`, `-TextFile`, `-WaitSeconds`, `-MaxChars` | Bash output, cwd, exit code; job ID while running |
| `wait [JOB_ID]` | `-WaitSeconds`, `-MaxChars` | New output or an unreported file result |

All run operations accept `-Cwd`, which changes the persistent Bash directory before execution. A missing directory prevents execution. Linux paths are passed literally with spaces, Unicode, quotes, and dollar signs preserved. Only `~` home expansion is performed in paths; environment variables are not expanded. Search patterns are passed separately from the literal root path.

## Searching

Both search operations use ripgrep inside WSL. Install `ripgrep` with your Linux package manager (for example, `sudo apt install ripgrep` on Ubuntu), or place `rg` at `~/.local/bin/rg`. The bridge discovers either location and does not install dependencies automatically.

```powershell
& .\work\wsl.ps1 grep 'class\s+\w+' -Root src -Glob '*.py'
& .\work\wsl.ps1 grep 'literal.*text' -Root . -Literal -IgnoreCase
& .\work\wsl.ps1 glob '**/*test*.py' -Root . -Glob '!vendor/**'
```

`grep` uses ripgrep's regex syntax by default, searches recursively, and returns one entry per matching line. `-Literal` switches to fixed text; `-IgnoreCase` affects grep content. Patterns must be nonempty and single-line. For multiline matching, alternate encodings, or other advanced rg options use `exec`. File roots return the basename; directory roots return paths relative to that directory. `-Root` does not change the persistent shell cwd.

`glob` uses native `rg --files --glob` semantics: `*.py` matches basenames recursively, `src/*.py` matches that directory level, `**` spans zero or more directories, and `!pattern` excludes. Additional `-Glob` values follow the same rules; later rules take precedence. **Explicit positive glob rules can include hidden or ignored paths**, just as with `rg -g`. Without such rules, grep respects ignore files and skips hidden paths. `-All` disables ignore filtering and includes hidden paths. Both operations exclude `.git` entries during traversal and do not follow directory symlinks. grep uses rg's default binary-file detection.

Searches use path order and stop when the global `-Limit` (default 100, max 1000) or output character budget `-MaxChars` (default 4000) is reached. Counts are returned entries, not total matches in the tree. `truncated: true` means the scan stopped or a line was clipped; there may be more results. The budget covers displayed result rows, excluding the small status/root/truncation headers and JSON punctuation. Narrow the root/pattern or increase the bound; searches do not save omitted matches. A single rg record above 8 MiB returns an explicit error. Non-UTF-8 bytes in search output are shown with replacement characters; use `exec` for byte-exact handling.

No matches is a successful empty result. Invalid patterns, missing roots/dependencies, and rg read errors are failures rather than an empty success. Search output is streamed and its child process is stopped at the bound. The normal Run/Wait transport remains unchanged.

## Writing and editing

For multiline text use a literal PowerShell here-string. Empty content and an empty replacement are supported:

```powershell
$content = @'
name: example
message: "$HOME stays literal"
'@
& .\work\wsl.ps1 write config/example.yml -Content $content -Parents
& .\work\wsl.ps1 edit config/example.yml -Old 'name: example' -New 'name: updated' -ExpectedHash HASH_FROM_READ
```

`write` refuses an existing destination unless given the expected SHA-256 or explicit overwrite. `edit` requires exactly one nonempty old-text match, unless `-All` is requested. A hash mismatch or an unexpected match count leaves the file untouched. Hash checks detect stale reads; the final concurrent-change check is best effort, not an atomic compare-and-swap.

Existing files are replaced atomically in their Linux directory, preserving owner/group, permission mode, and extended attributes. Special cases that cannot be preserved are rejected. New files use normal umask-based permissions and exclusive creation. New text defaults to LF; writes and edit replacements retain a consistently CRLF-formatted existing file. No Windows executable bits are copied into Linux files.

Text operations support UTF-8 files up to 8 MiB. Binary/non-UTF-8 files require `exec` and an appropriate tool. Reads can follow symlinks; writes and edits refuse symlinks, multiply hard-linked files, and files owned by another user. Use an explicit target or an appropriate `exec` operation for those cases. `mv` can move files, directories, or symlinks and supports cross-filesystem moves through GNU `mv`; its destination is always exact, never implicit directory nesting.

## Structured requests and output

For generated requests, use `-RequestFile` with a Windows UTF-8 JSON file. It accepts file operations `ls`, `read`, `write`, `edit`, `mv`, `grep`, and `glob`; other options are snake_case equivalents:

```json
{"op":"edit","path":"src/app.py","old":"old text","new":"new text","expected_hash":"SHA256_FROM_READ"}
```

Common fields: `path`, `expected_hash`, `parents`, `overwrite`. `ls` uses `limit`, `max_chars`, `all`; `read` uses `from`, `lines`, `max_chars`; `write` uses `content`; `edit` uses `old`, `new`, `all`; `mv` uses `to`. `grep`/`glob` use `path` as the search root and `pattern` as the query, plus `glob` (string or string array), `limit`, `max_chars`, `all`; grep also accepts `literal` and `ignore_case`. For example: `{"op":"grep","path":"src","pattern":"TODO","glob":["*.py"],"limit":30}`. Boolean fields must be JSON booleans, not strings.

```powershell
& .\work\wsl.ps1 -RequestFile .\work\request.json -Json
```

`-Json` returns the bridge envelope (`status`, `job`, `exit_code`, `cwd`) with a `result` object for completed file operations. Successful file results contain `ok: true`; failures contain `ok: false` and `error.code`/`error.message`. Transport failures can lack a file result, so inspect the envelope first. With `-WaitSeconds 0`, use `wait` to retrieve a pending result. Repeated waits do not replay completed file contents.
