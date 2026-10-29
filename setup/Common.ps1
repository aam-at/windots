<#
Shared logging, dry-run, and command-detection helpers for windots scripts.
Dot-source: . (Join-Path $PSScriptRoot 'Common.ps1')
Expects the dot-sourcing script to declare -DryRun where Invoke-IfNotDryRun
is used; [CmdletBinding()] gives it -Verbose for Write-Verbose detail.
#>

# The shared dotfiles checkout; Configure-Env.ps1 persists DOTFILES, and a
# fresh machine (before that step) falls back to Bootstrap.ps1's clone path.
$DotfilesRoot = if ($env:DOTFILES) { $env:DOTFILES } else { Join-Path $HOME 'dotfiles' }
$ScoopRoot = if ([string]::IsNullOrWhiteSpace($env:SCOOP)) {
    Join-Path $HOME 'scoop'
}
else { $env:SCOOP }
# This checkout; $PSScriptRoot is setup\ even when dot-sourced.
$WindotsRoot = Split-Path -Parent $PSScriptRoot
function WindotsPath([string]$Relative) { Join-Path $WindotsRoot $Relative }

$script:Warnings = [System.Collections.Generic.List[string]]::new()

function Write-Info($msg) { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Warn($msg) {
    $script:Warnings.Add($msg)
    Write-Host "[WARN]  $msg" -ForegroundColor Yellow
}

function Test-Command([string]$Name) {
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-IfNotDryRun {
    param([scriptblock]$Action)
    if (-not $DryRun) { & $Action }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [int[]]$SuccessExitCodes = @(0)
    )

    if ($DryRun) { return $true }

    $nativeOutput = @(& $Action 2>&1)
    if ($LASTEXITCODE -notin $SuccessExitCodes) {
        $nativeOutput | Out-Host
        Write-Warn "$Description failed with exit code $LASTEXITCODE."
        return $false
    }

    $nativeOutput | Out-String | Write-Verbose

    return $true
}

function Get-EmacsRoots {
    [pscustomobject]@{
        ConfigRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) {
            Join-Path $HOME '.config\emacs'
        }
        else { Join-Path $env:XDG_CONFIG_HOME 'emacs' }
        DataRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_DATA_HOME)) {
            Join-Path $HOME '.local\share\emacs'
        }
        else { Join-Path $env:XDG_DATA_HOME 'emacs' }
        StateRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_STATE_HOME)) {
            Join-Path $HOME '.local\state\emacs'
        }
        else { Join-Path $env:XDG_STATE_HOME 'emacs' }
    }
}

# Runs a program elevated (UAC prompt), by default pwsh; returns its exit code,
# or $null when elevation is declined.
function Invoke-Elevated(
    [string[]]$ArgumentList,
    [string]$FilePath = (Get-Process -Id $PID).Path
) {
    try {
        $start = @{ FilePath = $FilePath; ArgumentList = $ArgumentList; Verb = 'RunAs' }
        (Start-Process @start -Wait -PassThru).ExitCode
    }
    catch { $null }
}

# Reruns a script elevated with the parameters it was given ($PSBoundParameters),
# in a window left open to read the output. Warns when elevation is declined.
function Invoke-ScriptElevated(
    [string]$ScriptPath,
    [System.Collections.IDictionary]$Parameters
) {
    $quote = { "'" + ($args[0] -replace "'", "''") + "'" }
    $params = foreach ($name in $Parameters.Keys) {
        $value = $Parameters[$name]
        if ($value -is [switch]) { "-${name}:`$$([bool]$value)" }
        else { "-$name " + (@($value | ForEach-Object { & $quote $_ }) -join ',') }
    }
    $invocation = "& $(& $quote $ScriptPath) $params"
    $command = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
    $exitCode = Invoke-Elevated '-NoProfile', '-NoExit', '-EncodedCommand', $command
    if ($null -eq $exitCode) { Write-Warning 'Elevation declined.' }
}

# Per-profile Emacs paths and the environment variables its framework reads.
function Get-ProfilePaths {
    param([Parameter(Mandatory)][string]$Name)

    $roots = Get-EmacsRoots
    switch ($Name) {
        'doom' {
            $paths = [pscustomobject]@{
                Framework = Join-Path $roots.DataRoot 'doom'
                Profile = Join-Path $roots.ConfigRoot 'doom'
                Local = Join-Path $roots.StateRoot 'doom'
            }
            $paths | Add-Member Environment @{
                EMACSDIR = $paths.Framework
                DOOMDIR = $paths.Profile
                DOOMLOCALDIR = $paths.Local
            }
            return $paths
        }
        default {
            return [pscustomobject]@{
                Framework = Join-Path $roots.DataRoot 'spacemacs'
                Profile = Join-Path $roots.ConfigRoot $Name
                Local = $null
                Environment = @{ SPACEMACSDIR = (Join-Path $roots.ConfigRoot $Name) }
            }
        }
    }
}

# Runs $Body with $Vars set in the process environment, then restores them.
function Invoke-WithEnvironment([hashtable]$Vars, [scriptblock]$Body) {
    $saved = @{}
    try {
        foreach ($name in $Vars.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            Set-Item -Path "Env:$name" -Value $Vars[$name]
        }
        & $Body
    }
    finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) {
                Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
            }
            else { Set-Item -Path "Env:$name" -Value $saved[$name] }
        }
    }
}

function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]$identity
        return $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Stop-AutoHotkeyScript([string]$ScriptPath) {
    # Normalize so callers can pass '..' paths; AHK's command line holds the resolved
    # one.
    $ScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
    Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkeyUX.exe'" |
        Where-Object { $_.CommandLine -like "*$ScriptPath*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

# Running processes, grouped by Scoop app: the folder under scoop\apps they run from.
# Excludes this script and its parents, or selects only those with -HostProcessesOnly.
function Get-RunningScoopApps {
    param([switch]$HostProcessesOnly)

    $root = Join-Path $ScoopRoot 'apps\'
    $parents = @{}
    foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId) {
        $parents[[int]$p.ProcessId] = [int]$p.ParentProcessId
    }
    $own = [System.Collections.Generic.HashSet[int]]::new()
    $id = [int]$PID
    while ($id -and $own.Add($id)) { $id = $parents[$id] }
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Path -and $_.Path.StartsWith($root, 'OrdinalIgnoreCase') -and
            ($own.Contains($_.Id) -eq [bool]$HostProcessesOnly)
        } |
        Group-Object { ($_.Path.Substring($root.Length) -split '\\')[0] }
}

# Asks before stopping the running $Processes of $App. Returns $true when none are
# left running (none were, or the user said yes), $false when the user said no.
function Confirm-StopApp(
    [string]$App,
    [object[]]$Processes,
    [switch]$PauseRestart
) {
    if (-not $Processes) { return $true }
    $names = ($Processes | ForEach-Object Name | Sort-Object -Unique) -join ', '
    if ($DryRun) {
        Write-Info "$App is running ($names); would ask before stopping it."
        return $false
    }
    $answer = Read-Host "$App is running ($names). Stop it? [y/N]"
    if ($answer -notmatch '^y') {
        Write-Warn "$App is still running; it is not updated."
        return $false
    }
    if ($PauseRestart) { Set-ScoopAppRestartPaused $App $true }
    $Processes | Stop-Process -Force -ErrorAction SilentlyContinue
    $Processes | Wait-Process -ErrorAction SilentlyContinue
    return $true
}

function Set-ScoopAppRestartPaused([string]$App, [bool]$Paused) {
    $live = $liveApps | Where-Object ScoopApp -EQ $App
    if (-not $live -or -not $live['RestartOnCrash']) { return }
    $directory = Join-Path $env:LOCALAPPDATA 'windots\restart'
    $path = Join-Path $directory "$($live.App).paused"
    if ($Paused) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Set-Content -LiteralPath $path -Value $PID -NoNewline
    }
    else { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Test-ScoopAppRestartSupervisor([string]$App) {
    $live = $liveApps | Where-Object ScoopApp -EQ $App
    if (-not $live -or -not $live['RestartOnCrash']) { return $false }
    $pattern = "*Restart-OnCrash.ps1* -AppName $($live.App) *"
    [bool](Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" `
            -ErrorAction SilentlyContinue |
            Where-Object CommandLine -Like $pattern)
}

# Scoop skips an update while the app runs. True when $Output says so for $App.
function Test-ScoopBlocked([string]$App, [string]$Output) {
    $Output -match ('instances of "{0}" are still running' -f [regex]::Escape($App))
}

# Processes of a Scoop app: those running from its folder, plus the $liveApps names
# (AutoHotkey's shim copy runs from scoop\shims, outside the folder).
function Get-ScoopAppProcesses([string]$App) {
    $names = @($liveApps | Where-Object ScoopApp -EQ $App | ForEach-Object Processes)
    $fromFolder = @(Get-RunningScoopApps | Where-Object Name -EQ $App |
            ForEach-Object Group)
    $byName = @()
    if ($names) {
        $byName = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    }
    @($fromFolder + $byName) | Sort-Object Id -Unique
}

# Apps Stop-ForUpdate stopped in this run; only these are started again.
$script:stoppedApps = [System.Collections.Generic.List[string]]::new()

# Stops the running processes of a Scoop app whose update is blocked. $autoStopApps
# close gracefully without asking, so their windows save state; other apps ask
# first. Returns $true when the update can go ahead.
function Stop-ForUpdate([string]$App) {
    if (Get-RunningScoopApps -HostProcessesOnly | Where-Object Name -EQ $App) {
        Write-Warn ("$App is hosting this script or its parent shell; it is not " +
            'updated. Close those sessions and run scripts\Update-Apps.cmd ' +
            'from Explorer to update from Windows PowerShell instead.')
        return $false
    }
    $procs = @(Get-ScoopAppProcesses $App)
    if (-not $procs) { return $true }
    if ($App -in @($autoStopApps | ForEach-Object ScoopApp)) {
        if ($DryRun) {
            Write-Info "$App is running; would close it for its update."
            return $false
        }
        Write-Info "Closing $App for its update"
        Set-ScoopAppRestartPaused $App $true
        $procs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
        $procs | Wait-Process -Timeout 20 -ErrorAction SilentlyContinue
        $script:stoppedApps.Add($App)
        # Closing a window can leave background processes or spawn new children.
        # Refresh the list, then wait for forced exits before Scoop checks again.
        $remaining = @(Get-ScoopAppProcesses $App)
        if ($remaining) {
            $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
            $remaining | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
        }
        if (@(Get-ScoopAppProcesses $App).Count -gt 0) {
            Write-Warn "$App is still running after closing it; it is not updated."
            Restart-ScoopLiveApp $App
            return $false
        }
        return $true
    }
    $live = $liveApps | Where-Object ScoopApp -EQ $App
    $pauseRestart = [bool]($live -and $live['RestartOnCrash'])
    if (Confirm-StopApp $App $procs -PauseRestart:$pauseRestart) {
        $script:stoppedApps.Add($App)
        return $true
    }
    return $false
}

# Starts an app stopped by Stop-ForUpdate again, right after its update: auto-stop
# apps with their last session, the others through their Startup shortcuts.
function Restart-ScoopLiveApp([string]$App) {
    if ($App -notin $script:stoppedApps) { return }
    Set-ScoopAppRestartPaused $App $false
    $auto = $autoStopApps | Where-Object ScoopApp -EQ $App
    if ($auto) {
        Write-Info "Restarting $App"
        $exe = Join-Path $ScoopRoot "apps\$App\current\$($auto.Exe)"
        $start = @{ FilePath = $exe }
        if ($auto['Arguments']) { $start.ArgumentList = $auto['Arguments'] }
        Invoke-IfNotDryRun { Start-Process @start }
        return
    }
    $live = $liveApps | Where-Object ScoopApp -EQ $App
    if (-not $live) { return }
    if (Test-ScoopAppRestartSupervisor $App) {
        Write-Info "$($live.App) crash supervisor will relaunch it."
        return
    }
    $startup = [Environment]::GetFolderPath('Startup')
    $links = @($live.Shortcuts | ForEach-Object { Join-Path $startup "$_.lnk" } |
            Where-Object { Test-Path -LiteralPath $_ })
    if (-not $links) {
        Write-Warn "$($live.App) has no Startup shortcut; start it by hand."
        return
    }
    Write-Info "Restarting $($live.App)"
    Invoke-IfNotDryRun { $links | ForEach-Object { Invoke-Item -LiteralPath $_ } }
}
