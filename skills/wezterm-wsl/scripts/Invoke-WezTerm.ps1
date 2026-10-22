#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('List', 'Read', 'Send', 'Key', 'Attach', 'Run', 'Wait')]
    [string] $Action = 'Run',
    [string] $SocketPath,
    [int] $PaneId = -1,
    [string] $Text,
    [string] $TextFile,
    [switch] $Enter,
    [ValidateSet('Enter', 'CtrlC', 'CtrlD', 'Escape')]
    [string] $Key,
    [int] $StartLine = -40,
    [string] $WezTermPath,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')]
    [string] $Session = 'default',
    [string] $StateRoot = (Join-Path (Get-Location) 'work\wezterm-wsl'),
    [string] $LinuxStateRoot,
    [ValidateRange(0, 25)]
    [int] $WaitSeconds = 20,
    [ValidateRange(128, 100000)]
    [int] $MaxChars = 4000,
    [ValidatePattern('^[a-f0-9]{12}$')]
    [string] $Job,
    [switch] $ResetSession,
    [switch] $Metrics,
    [ValidateRange(1, 30)]
    [int] $TimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:WezCliCalls = 0
$script:InvocationParameters = $PSBoundParameters

function Find-WezTerm {
    if ($WezTermPath) {
        return (Resolve-Path -LiteralPath $WezTermPath -ErrorAction Stop).Path
    }
    $installed = Get-Command wezterm.exe -ErrorAction SilentlyContinue
    if ($installed) { return $installed.Source }
    $paths = @()
    if ($env:ProgramFiles) { $paths += Join-Path $env:ProgramFiles 'WezTerm\wezterm.exe' }
    if ($env:LOCALAPPDATA) { $paths += Join-Path $env:LOCALAPPDATA 'Programs\WezTerm\wezterm.exe' }
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    throw 'WezTerm executable not found. Supply -WezTermPath for a nonstandard installation.'
}

function Get-GuiEndpoint([string] $Path) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw 'SocketPath must be an absolute path.'
    }
    $resolved = [IO.Path]::GetFullPath($Path)
    $fileName = [IO.Path]::GetFileName($resolved)
    if ($fileName -notmatch '^gui-sock-(\d+)$') {
        throw 'This helper targets GUI sockets named gui-sock-PID, not background mux servers.'
    }
    $guiId = [int] $Matches[1]
    if (-not (Test-Path -LiteralPath $resolved)) {
        throw "Socket does not exist or is inaccessible: $resolved"
    }
    $gui = Get-Process -Id $guiId -ErrorAction SilentlyContinue
    if (-not $gui -or $gui.ProcessName -ne 'wezterm-gui') {
        throw "No live wezterm-gui process is visible for $resolved. Rediscover or check permissions."
    }
    return [pscustomobject]@{ socket_path = $resolved; gui_process_id = $guiId }
}

function Invoke-WezCli {
    param([string] $Endpoint, [string[]] $Arguments, [AllowNull()][string] $InputText = $null)
    $script:WezCliCalls++
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.Environment['WEZTERM_UNIX_SOCKET'] = $Endpoint
    foreach ($arg in @('cli', '--no-auto-start') + $Arguments) {
        [void] $startInfo.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void] $process.Start()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw 'WezTerm CLI timed out. Input delivery may be ambiguous; read the pane before retrying a send.'
        }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "WezTerm CLI failed ($($process.ExitCode)): $stderr"
        }
        return $stdout
    }
    finally { $process.Dispose() }
}

function Get-Panes([string] $Endpoint) {
    $result = Invoke-WezCli -Endpoint $Endpoint -Arguments @('list', '--format', 'json')
    return @($result | ConvertFrom-Json)
}

$script:Executable = Find-WezTerm

if ($Action -eq 'List') {
    $candidates = @()
    $errors = @()
    if ($SocketPath) {
        $candidates += $SocketPath
    }
    else {
        if ($env:WEZTERM_UNIX_SOCKET) { $candidates += $env:WEZTERM_UNIX_SOCKET }
        $directories = @()
        if ($env:USERPROFILE) { $directories += Join-Path $env:USERPROFILE '.local\share\wezterm' }
        if ($env:XDG_RUNTIME_DIR) { $directories += Join-Path $env:XDG_RUNTIME_DIR 'wezterm' }
        foreach ($directory in @($directories | Select-Object -Unique)) {
            try {
                if (Test-Path -LiteralPath $directory) {
                    $candidates += @(Get-ChildItem -LiteralPath $directory -Filter 'gui-sock-*' -ErrorAction Stop |
                        ForEach-Object { $_.FullName })
                }
            }
            catch { $errors += [pscustomobject]@{ socket_path = $directory; error = $_.Exception.Message } }
        }
    }
    $candidates = @($candidates | Select-Object -Unique)
    $sessions = @()
    foreach ($candidate in $candidates) {
        try {
            $endpoint = Get-GuiEndpoint $candidate
            $panes = @(Get-Panes $endpoint.socket_path)
            $sessions += [pscustomobject]@{
                socket_path = $endpoint.socket_path
                gui_process_id = $endpoint.gui_process_id
                panes = @($panes | Select-Object pane_id, workspace, title)
            }
        }
        catch { $errors += [pscustomobject]@{ socket_path = $candidate; error = $_.Exception.Message } }
    }
    [pscustomobject]@{
        wezterm_path = $script:Executable
        candidate_count = $candidates.Count
        sessions = $sessions
        connection_errors = $errors
    } | ConvertTo-Json -Depth 15 -Compress
    return
}

. (Join-Path $PSScriptRoot 'WezTerm-Bridge.ps1')
if ($Action -in @('Attach', 'Run', 'Wait')) {
    Invoke-BridgeAction
    return
}
if (-not $SocketPath -and $PaneId -lt 0) {
    $binding = Read-BridgeSession
    Assert-BridgeBinding $binding
    $SocketPath = $binding.socket_path
    $PaneId = $binding.pane_id
}
if (-not $SocketPath -or $PaneId -lt 0) { throw 'Read, Send, and Key require an explicit -SocketPath and nonnegative -PaneId.' }
$endpoint = Get-GuiEndpoint $SocketPath
$panes = @(Get-Panes $endpoint.socket_path)
if (-not @($panes | Where-Object { $_.pane_id -eq $PaneId }).Count) {
    throw "Pane $PaneId is not present in this GUI. Rediscover; do not target a different pane automatically."
}

switch ($Action) {
    'Read' {
        $result = Invoke-WezCli -Endpoint $endpoint.socket_path -Arguments @(
            'get-text', '--pane-id', [string] $PaneId, '--start-line', [string] $StartLine
        )
        $result = $result.TrimEnd()
        if ($result.Length -gt $MaxChars) { $result = "[older screen text omitted]`n" + $result.Substring($result.Length - $MaxChars) }
        Write-Output $result
    }
    'Send' {
        if ($PSBoundParameters.ContainsKey('Text') -eq $PSBoundParameters.ContainsKey('TextFile')) {
            throw 'Supply exactly one of -Text and -TextFile.'
        }
        $payload = if ($TextFile) {
            [IO.File]::ReadAllText((Resolve-Path -LiteralPath $TextFile).Path, [Text.Encoding]::UTF8)
        } else { $Text }
        if ([string]::IsNullOrEmpty($payload)) { throw 'Text is empty. Use -Action Key -Key Enter to submit existing input.' }
        if ($payload.Length -gt 65536) { throw 'Text exceeds 65536 characters. Use a script file in WSL for a large program.' }
        [void] (Invoke-WezCli -Endpoint $endpoint.socket_path -Arguments @('send-text', '--pane-id', [string] $PaneId) -InputText $payload)
        if ($Enter) {
            [void] (Invoke-WezCli -Endpoint $endpoint.socket_path -Arguments @('send-text', '--pane-id', [string] $PaneId, '--no-paste') -InputText ([string][char]13))
        }
        [pscustomobject]@{ pane_id = $PaneId; sent = $true; enter_sent = [bool] $Enter; completion_verified = $false } | ConvertTo-Json -Compress
    }
    'Key' {
        if (-not $Key) { throw 'Key action requires -Key.' }
        $keyCode = @{ Enter = 13; CtrlC = 3; CtrlD = 4; Escape = 27 }[$Key]
        [void] (Invoke-WezCli -Endpoint $endpoint.socket_path -Arguments @('send-text', '--pane-id', [string] $PaneId, '--no-paste') -InputText ([string][char] $keyCode))
        [pscustomobject]@{ pane_id = $PaneId; key = $Key; sent = $true; completion_verified = $false } | ConvertTo-Json -Compress
    }
}
