# Dot-sourced by Invoke-WezTerm.ps1. No services, network listeners, or shell profiles.
$script:BridgeRoot = [IO.Path]::GetFullPath($StateRoot)
if ($script:BridgeRoot -notmatch '^[A-Za-z]:[\\/]') {
    throw 'StateRoot must be on a local Windows drive, accessible to WSL.'
}
$script:SessionFile = Join-Path $script:BridgeRoot "$Session.json"
$script:Utf8 = [Text.UTF8Encoding]::new($false)

function Write-BridgeText([string] $Path, [string] $Content) {
    [IO.File]::WriteAllText($Path, $Content, $script:Utf8)
}

function Write-BridgeJson([string] $Path, $Value) {
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    Write-BridgeText $temp ($Value | ConvertTo-Json -Depth 12 -Compress)
    [IO.File]::Move($temp, $Path, $true)
}

function Read-BridgeSession {
    if (-not (Test-Path -LiteralPath $script:SessionFile)) {
        throw "Session '$Session' is not attached in $script:BridgeRoot. Use List, Read, then Attach once."
    }
    return Get-Content -LiteralPath $script:SessionFile -Raw | ConvertFrom-Json
}

function Assert-BridgeBinding($Binding) {
    $current = Get-GuiEndpoint $Binding.socket_path
    if ($current.gui_process_id -ne $Binding.gui_process_id -or $Binding.shell_pid -notmatch '^\d+$') {
        throw 'Invalid cached session identity; attach again.'
    }
    $gui = Get-Process -Id $Binding.gui_process_id
    if ($gui.StartTime.ToUniversalTime().Ticks.ToString() -ne $Binding.gui_start_ticks) {
        throw 'The GUI process has changed. Rediscover and attach; do not reuse this session.'
    }
}

function Quote-Bash([string] $Value) { return "'" + $Value.Replace("'", "'\''") + "'" }

function Get-JobDirectory([string] $Id) {
    if ($Id -notmatch '^[a-f0-9]{12}$') { throw 'Invalid job ID in session state.' }
    return Join-Path $script:BridgeRoot "jobs\$Id"
}

function Test-JobDone([string] $Directory) {
    $done = Join-Path $Directory 'done'
    if (-not [IO.File]::Exists($done)) { return $false }
    return [IO.File]::ReadAllText($done).Trim() -match '^\d{1,3}$'
}

function Wait-JobNotification([string] $Directory, [int] $Seconds) {
    # Watch only the atomic completion file. The two-second status check is a
    # fallback for a missed/cross-filesystem notification; it never captures panes.
    $watcher = [IO.FileSystemWatcher]::new($Directory, 'done')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $checks = 0
    try {
        $watcher.EnableRaisingEvents = $true
        while ($true) {
            $checks++
            if (Test-JobDone $Directory) { return $checks }
            $remaining = $Seconds * 1000 - [int] $clock.ElapsedMilliseconds
            if ($remaining -le 0) { return $checks }
            [void] $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, [Math]::Min(2000, $remaining))
        }
    }
    finally { $watcher.Dispose() }
}

function Get-StreamDelta([string] $Path, [long] $Offset, [bool] $Complete) {
    if (-not [IO.File]::Exists($Path)) {
        return @{ text = ''; offset = $Offset; truncated = $false }
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $end = $stream.Length
        if ($end -lt $Offset) { throw 'Output log was truncated externally; refusing to reuse its cursor.' }
        $start = [Math]::Max($Offset, $end - ($MaxChars * 4L + 4))
        [void] $stream.Seek($start, [IO.SeekOrigin]::Begin)
        $bytes = [byte[]]::new([int] ($end - $start))
        $count = 0
        while ($count -lt $bytes.Length) {
            $n = $stream.Read($bytes, $count, $bytes.Length - $count)
            if ($n -eq 0) { break }
            $count += $n
        }
    }
    finally { $stream.Dispose() }
    $first = 0
    if ($start -gt $Offset) {
        while ($first -lt $count -and ($bytes[$first] -band 0xC0) -eq 0x80) { $first++ }
    }
    $usable = $count
    if (-not $Complete -and $count -gt $first) {
        $lead = $count - 1
        while ($lead -gt $first -and ($bytes[$lead] -band 0xC0) -eq 0x80) { $lead-- }
        $byte = $bytes[$lead]
        $width = if ($byte -ge 0xC2 -and $byte -le 0xDF) { 2 } elseif ($byte -ge 0xE0 -and $byte -le 0xEF) { 3 } elseif ($byte -ge 0xF0 -and $byte -le 0xF4) { 4 } else { 1 }
        if ($count - $lead -lt $width) { $usable = $lead }
    }
    $value = $script:Utf8.GetString($bytes, $first, [Math]::Max(0, $usable - $first))
    $truncated = $start -gt $Offset -or $value.Length -gt $MaxChars
    if ($value.Length -gt $MaxChars) {
        $cut = $value.Length - $MaxChars
        if ([char]::IsLowSurrogate($value[$cut])) { $cut++ }
        $value = $value.Substring($cut)
    }
    return @{ text = $value; offset = $start + $usable; truncated = $truncated }
}

function Get-JobResult([string] $Id, [int] $Checks) {
    $dir = Get-JobDirectory $Id
    $jobFile = Join-Path $dir 'job.json'
    $record = Get-Content -LiteralPath $jobFile -Raw | ConvertFrom-Json
    if ($record.session -ne $Session) { throw 'This job belongs to a different session.' }
    $complete = Test-JobDone $dir
    $out = Get-StreamDelta (Join-Path $dir 'stdout') $record.stdout_offset $complete
    $err = Get-StreamDelta (Join-Path $dir 'stderr') $record.stderr_offset $complete
    $result = [ordered]@{
        status = $(if ($complete) { 'done' } elseif ($record.delivery -eq 'sent') { 'running' } else { 'delivery_unknown' })
        job = $Id
    }
    if ($complete) {
        $result.exit_code = [int] [IO.File]::ReadAllText((Join-Path $dir 'done')).Trim()
        $cwdPath = Join-Path $dir 'cwd'
        if ([IO.File]::Exists($cwdPath)) { $result.cwd = [IO.File]::ReadAllText($cwdPath) }
    }
    if ($out.text) { $result.stdout = $out.text }
    if ($err.text) { $result.stderr = $err.text }
    if ($complete -and $record.PSObject.Properties['kind'] -and $record.kind -eq 'file' -and -not $record.result_delivered) {
        $resultPath = Join-Path $dir 'result.json'
        if ([IO.File]::Exists($resultPath)) {
            $result.result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            $record.result_delivered = $true
            $result.Remove('stdout')
            $result.Remove('stderr')
        }
    }
    if ($out.truncated -or $err.truncated) {
        $result.truncated = $true
        $result.full_output_directory = $dir
    }
    $record.stdout_offset = $out.offset
    $record.stderr_offset = $err.offset
    Write-BridgeJson $jobFile $record
    if ($Metrics) { $result.metrics = @{ wezterm_cli_calls = $script:WezCliCalls; terminal_captures = 0; completion_checks = $Checks } }
    return $result
}

function Send-BridgeSource($Binding, [string] $LinuxFile) {
    $line = 'builtin source ' + (Quote-Bash $LinuxFile)
    # This is a generated, single-line source instruction to an attached Bash
    # prompt, not arbitrary pasted program text: submit it in one CLI call.
    [void] (Invoke-WezCli -Endpoint $Binding.socket_path -Arguments @('send-text', '--pane-id', [string] $Binding.pane_id, '--no-paste') -InputText ($line + [char]13))
}

function Invoke-BridgeAction {
    [void] [IO.Directory]::CreateDirectory($script:BridgeRoot)
    try {
        $lock = [IO.File]::Open((Join-Path $script:BridgeRoot "$Session.lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch { throw "Session '$Session' is busy in another helper call. Do not issue concurrent commands to it." }
    try {
        if ($Action -eq 'Attach') {
            if (-not $SocketPath -or $PaneId -lt 0) { throw 'Attach requires an explicit SocketPath and PaneId, after reading the idle Bash prompt.' }
            if (Test-Path -LiteralPath $script:SessionFile) {
                $previous = Read-BridgeSession
                if ($previous.job -and -not (Test-JobDone (Get-JobDirectory $previous.job)) -and -not $ResetSession) {
                    throw 'The attached session has an unfinished job. Wait, or inspect and resolve it before Attach -ResetSession.'
                }
            }
            $endpoint = Get-GuiEndpoint $SocketPath
            $panes = @(Get-Panes $endpoint.socket_path)
            if (-not @($panes | Where-Object pane_id -eq $PaneId).Count) { throw 'Selected pane is absent.' }
            $gui = Get-Process -Id $endpoint.gui_process_id
            $linuxRoot = if ($LinuxStateRoot) { $LinuxStateRoot.TrimEnd('/') } else {
                '/mnt/' + $script:BridgeRoot.Substring(0, 1).ToLowerInvariant() + $script:BridgeRoot.Substring(2).Replace('\', '/')
            }
            if (-not $linuxRoot.StartsWith('/')) { throw 'LinuxStateRoot must be an absolute Linux path.' }
            $binding = [pscustomobject]@{
                socket_path = $endpoint.socket_path; pane_id = $PaneId
                gui_process_id = $endpoint.gui_process_id
                gui_start_ticks = $gui.StartTime.ToUniversalTime().Ticks.ToString()
                linux_root = $linuxRoot; shell_pid = ''; distro = ''; job = $null
            }
            $probeId = [guid]::NewGuid().ToString('N').Substring(0, 12)
            $probeDir = Get-JobDirectory $probeId
            [void] [IO.Directory]::CreateDirectory($probeDir)
            $linuxDir = "$linuxRoot/jobs/$probeId"
            $q = Quote-Bash $linuxDir
            $probe = @'
if [ -z "${BASH_VERSION:-}" ] || [ -z "${WSL_DISTRO_NAME:-}" ]; then
  printf 'Run mode requires Bash inside WSL.\n' > __DIR__/error
else
  printf '%s' "$$" > __DIR__/shell_pid
  printf '%s' "$WSL_DISTRO_NAME" > __DIR__/distro
  printf '%s' "$PWD" > __DIR__/cwd
fi
printf '0\n' > __DIR__/done.tmp
command mv -- __DIR__/done.tmp __DIR__/done
'@
            Write-BridgeText (Join-Path $probeDir 'probe.sh') ($probe.Replace('__DIR__', $q).Replace("`r`n", "`n") + "`n")
            Send-BridgeSource $binding "$linuxDir/probe.sh"
            [void] (Wait-JobNotification $probeDir ([Math]::Max(1, $WaitSeconds)))
            if (-not (Test-JobDone $probeDir)) { throw 'Attach probe did not complete. Read the pane; check Bash, the WSL mount path, and permissions. Do not resend blindly.' }
            if ([IO.File]::Exists((Join-Path $probeDir 'error'))) { throw [IO.File]::ReadAllText((Join-Path $probeDir 'error')) }
            $binding.shell_pid = [IO.File]::ReadAllText((Join-Path $probeDir 'shell_pid'))
            if ($binding.shell_pid -notmatch '^\d+$') { throw 'Invalid shell identity in probe.' }
            $binding.distro = [IO.File]::ReadAllText((Join-Path $probeDir 'distro'))
            Write-BridgeJson $script:SessionFile $binding
            @{ status = 'attached'; session = $Session; distro = $binding.distro; shell_pid = $binding.shell_pid; cwd = [IO.File]::ReadAllText((Join-Path $probeDir 'cwd')); state_root = $script:BridgeRoot } | ConvertTo-Json -Compress
            return
        }

        $binding = Read-BridgeSession
        if ($Action -eq 'Run') {
            Assert-BridgeBinding $binding
            if ($binding.job -and -not (Test-JobDone (Get-JobDirectory $binding.job))) {
                throw "Job $($binding.job) is unfinished. Use Wait or Read; a second command was not sent."
            }
            $inputCount = @('Text', 'TextFile', 'RequestFile' | Where-Object { $script:InvocationParameters.ContainsKey($_) }).Count
            if ($inputCount -ne 1) { throw 'Run requires exactly one of Text, TextFile, and RequestFile.' }
            $kind = if ($RequestFile) { 'file' } else { 'shell' }
            if ($RequestFile) {
                $requestText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $RequestFile).Path, $script:Utf8)
                $request = $requestText | ConvertFrom-Json -AsHashtable
                if ($request -isnot [System.Collections.IDictionary] -or $request.op -notin @('ls', 'read', 'write', 'edit', 'mv', 'grep', 'glob')) { throw 'RequestFile requires a file operation: ls, read, write, edit, mv, grep, or glob.' }
            }
            else {
                $command = if ($TextFile) { [IO.File]::ReadAllText((Resolve-Path -LiteralPath $TextFile).Path, $script:Utf8) } else { $Text }
                if ([string]::IsNullOrWhiteSpace($command)) { throw 'Command is empty.' }
            }
            $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
            $dir = Get-JobDirectory $id
            [void] [IO.Directory]::CreateDirectory($dir)
            $linuxDir = "$($binding.linux_root)/jobs/$id"
            if ($kind -eq 'file') {
                Write-BridgeText (Join-Path $dir 'request.json') $requestText
                [IO.File]::Copy((Join-Path $PSScriptRoot 'wsl-files.py'), (Join-Path $dir 'files.py'))
                $command = 'python3 ' + (Quote-Bash "$linuxDir/files.py") + ' ' + (Quote-Bash "$linuxDir/request.json") + ' ' + (Quote-Bash "$linuxDir/result.json")
            }
            if ($Cwd) {
                $quotedCwd = if ($Cwd -eq '~') { '"$HOME"' } elseif ($Cwd.StartsWith('~/')) { '"$HOME"/' + (Quote-Bash $Cwd.Substring(2)) } else { Quote-Bash $Cwd }
                $command = 'if builtin cd -- ' + $quotedCwd + "; then`n" + $command + "`nelse`n  false`nfi"
            }
            Write-BridgeText (Join-Path $dir 'command.sh') ($command.Replace("`r`n", "`n") + "`n")
            $driver = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'run-driver.bash'))
            $driver = $driver.Replace('__DIR__', (Quote-Bash $linuxDir)).Replace('__EXPECTED_PID__', $binding.shell_pid).Replace('__VAR__', "__cwz_$id")
            Write-BridgeText (Join-Path $dir 'run.sh') ($driver.Replace("`r`n", "`n"))
            $record = [pscustomobject]@{ session = $Session; delivery = 'attempting'; stdout_offset = 0L; stderr_offset = 0L; kind = $kind; result_delivered = $false }
            Write-BridgeJson (Join-Path $dir 'job.json') $record
            $binding.job = $id
            Write-BridgeJson $script:SessionFile $binding
            try {
                Send-BridgeSource $binding "$linuxDir/run.sh"
                $record.delivery = 'sent'
                Write-BridgeJson (Join-Path $dir 'job.json') $record
            }
            catch {
                @{ status = 'delivery_unknown'; job = $id; error = $_.Exception.Message; next = 'Wait or Read before any retry.' } | ConvertTo-Json -Compress
                return
            }
        }
        else {
            $id = if ($Job) { $Job } else { $binding.job }
            if (-not $id) { throw 'There is no job to wait for.' }
            $dir = Get-JobDirectory $id
            if (-not [IO.File]::Exists((Join-Path $dir 'job.json'))) { throw 'Job record does not exist.' }
        }
        $checks = Wait-JobNotification $dir $WaitSeconds
        $result = Get-JobResult $id $checks
        if ($result.status -ne 'done') {
            try { Assert-BridgeBinding $binding } catch { $result.status = 'session_lost'; $result.error = $_.Exception.Message }
        }
        $result | ConvertTo-Json -Depth 8 -Compress
    }
    finally { $lock.Dispose() }
}
