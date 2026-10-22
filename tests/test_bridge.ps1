#requires -Version 7.0
param(
    [Parameter(Mandatory)][string] $Entry,
    [string] $StateRoot = (Join-Path (Get-Location) 'work\wezterm-wsl')
)
$ErrorActionPreference = 'Stop'
function Invoke-TestWsl([hashtable] $Arguments) {
    $raw = & $Entry @Arguments -StateRoot $StateRoot -Json
    return $raw | ConvertFrom-Json -AsHashtable
}
function Assert-That($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
$initial = Invoke-TestWsl @{ Op = 'exec'; Target = 'pwd' }
$original = $initial.cwd
$failedCommand = Invoke-TestWsl @{ Op = 'exec'; Target = 'bash -c "exit 7"' }
Assert-That ($failedCommand.exit_code -eq 7 -and $global:LASTEXITCODE -eq 7) 'command exit code was not preserved'
$created = Invoke-TestWsl @{ Op = 'exec'; Target = 'mktemp -d /tmp/wezterm-files-XXXXXX' }
$scratch = $created.stdout.Trim()
if ($scratch -notmatch '^/tmp/wezterm-files-[A-Za-z0-9]+$') { throw 'Unexpected scratch directory; refusing cleanup.' }
try {
    $changed = Invoke-TestWsl @{ Op = 'cd'; Target = $scratch }
    Assert-That ($changed.cwd -eq $scratch) 'cd did not persist'
    $name = "space ' 中文 `$literal.txt"
    $written = Invoke-TestWsl @{ Op = 'write'; Target = $name; Content = "first`r`n中文`r`n"; Metrics = $true }
    Assert-That ($written.result.ok -and $written.metrics.wezterm_cli_calls -eq 1 -and $written.metrics.terminal_captures -eq 0) 'write transport failed'
    $read = Invoke-TestWsl @{ Op = 'read'; Target = $name; From = 2; Lines = 1 }
    Assert-That ($read.result.content -eq "中文`n") 'Unicode, newline, or line-range mismatch'
    $edited = Invoke-TestWsl @{ Op = 'edit'; Target = $name; Old = 'first'; New = 'updated'; ExpectedHash = $read.result.sha256 }
    Assert-That ($edited.result.ok) 'edit failed'
    $stale = Invoke-TestWsl @{ Op = 'edit'; Target = $name; Old = 'updated'; New = 'lost'; ExpectedHash = $read.result.sha256 }
    Assert-That ($stale.exit_code -ne 0 -and $stale.result.error.code -eq 'conflict') 'stale hash was accepted'
    $empty = Invoke-TestWsl @{ Op = 'write'; Target = 'empty'; Content = '' }
    Assert-That ($empty.result.ok -and $empty.result.bytes -eq 0) 'empty content lost in parameter forwarding'
    $refused = Invoke-TestWsl @{ Op = 'mv'; Target = $name; To = 'empty' }
    Assert-That ($refused.result.error.code -eq 'exists') 'mv overwrote destination'
    $moved = Invoke-TestWsl @{ Op = 'mv'; Target = $name; To = 'renamed.txt' }
    Assert-That ($moved.result.ok) 'mv failed'
    $listed = Invoke-TestWsl @{ Op = 'ls'; Limit = 1 }
    Assert-That ($listed.result.entries.Count -eq 1 -and $listed.result.omitted -eq 1) 'ls limits failed'
    $failure = Invoke-TestWsl @{ Op = 'exec'; Target = 'printf SHOULD_NOT_RUN'; Cwd = "$scratch/absent" }
    Assert-That ($failure.exit_code -ne 0 -and -not $failure.ContainsKey('stdout')) 'command ran after failed cd'
    [void] (Invoke-TestWsl @{ Op = 'exec'; Target = "__wez_files_test='persistent'"; Cwd = $scratch })
    $persisted = Invoke-TestWsl @{ Op = 'exec'; Target = 'printf %s "$__wez_files_test"' }
    Assert-That ($persisted.stdout -eq 'persistent') 'shell variable did not persist'
    $pending = Invoke-TestWsl @{ Op = 'exec'; Target = 'printf EARLY; sleep 2; printf LATE'; WaitSeconds = 0 }
    Assert-That ($pending.status -eq 'running') 'long job did not return running'
    $rejected = $false
    try { [void] (Invoke-TestWsl @{ Op = 'exec'; Target = 'printf OVERLAP' }) } catch { $rejected = $_.ToString().Contains('unfinished') }
    Assert-That $rejected 'overlapping run was not rejected'
    $finished = Invoke-TestWsl @{ Op = 'wait'; Target = $pending.job; WaitSeconds = 5; Metrics = $true }
    Assert-That ($finished.status -eq 'done' -and $finished.metrics.wezterm_cli_calls -eq 0) 'Wait used terminal calls or failed'
    Assert-That (($pending.stdout + $finished.stdout) -eq 'EARLYLATE') 'incremental output was lost or duplicated'
    $repeated = Invoke-TestWsl @{ Op = 'wait'; Target = $pending.job }
    Assert-That (-not $repeated.ContainsKey('stdout')) 'Wait replayed output'
    $filePending = Invoke-TestWsl @{ Op = 'read'; Target = 'renamed.txt'; WaitSeconds = 0 }
    $fileDone = if ($filePending.status -eq 'done') { $filePending } else { Invoke-TestWsl @{ Op = 'wait'; Target = $filePending.job; WaitSeconds = 5 } }
    Assert-That ($fileDone.result.ok -and $fileDone.result.content.StartsWith('updated')) 'structured result was lost across Wait'
    $fileAgain = Invoke-TestWsl @{ Op = 'wait'; Target = $fileDone.job }
    Assert-That (-not $fileAgain.ContainsKey('result')) 'Wait replayed structured result'
    Write-Output 'Bridge integration checks passed: all seven operations, Unicode paths, hash conflicts, persistent state, guarded cwd, bounded output, overlap rejection, and incremental Wait.'
}
finally {
    [void] (Invoke-TestWsl @{ Op = 'exec'; Target = 'unset __wez_files_test'; Cwd = $original; WaitSeconds = 5 })
    $cleanup = 'python3 -c ''import shutil; shutil.rmtree("' + $scratch + '")'''
    [void] (Invoke-TestWsl @{ Op = 'exec'; Target = $cleanup })
}
