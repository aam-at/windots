<#
Manage named Emacs daemons for the profiles in the shared dotfiles repository.

Usage:
  .\Emacs-Daemon.ps1 {switch|start|stop|restart|open|status} PROFILE
      [EMACSCLIENT-ARG ...]

Logs, in %LOCALAPPDATA%\windots: emacs-daemon.log has every start, stop and
failure (otherwise invisible under conhost --headless); emacs-<profile>.log has
the daemon's own output from its last start.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('switch', 'start', 'stop', 'restart', 'open', 'status')]
    [string]$Action,

    [Parameter(Mandatory, Position = 1)]
    [ValidateSet('doom', 'spacemacs')]
    [string]$EmacsProfile,

    [Parameter(Position = 2, ValueFromRemainingArguments = $true)]
    [string[]]$EmacsClientArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\setup\Common.ps1')
$roots = Get-EmacsRoots

$logDir = Join-Path $env:LOCALAPPDATA 'windots'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
function Write-Log([string]$Message) {
    $entry = "$(Get-Date -Format s) $EmacsProfile ${Action}: $Message"
    Add-Content -LiteralPath (Join-Path $logDir 'emacs-daemon.log') -Value $entry
}
trap { Write-Log "failed: $_"; break }

function Get-RequiredCommand {
    param([Parameter(Mandatory)][string]$Name)

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command not found on PATH: $Name"
    }
    return @($command)[0].Source
}

function Get-ServerArg {
    param([Parameter(Mandatory)][string]$Name)

    # Windows emacsclient has no --socket-name (servers use TCP + an auth file).
    # Both frameworks keep that file in <init-directory>\server\<daemon name>.
    return "--server-file=$(Join-Path $roots.DataRoot "$Name\server\$Name")"
}

function Assert-ProfileInstalled {
    param([Parameter(Mandatory)][psobject]$ProfilePaths)

    # Doom's framework ships only early-init.el; Spacemacs ships init.el.
    $initFiles = @('init.el', 'early-init.el') | Where-Object {
        Test-Path -LiteralPath (Join-Path $ProfilePaths.Framework $_)
    }
    if (-not $initFiles) {
        throw "Emacs framework is not installed at $($ProfilePaths.Framework)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ProfilePaths.Profile 'init.el'))) {
        throw "Emacs profile is not installed at $($ProfilePaths.Profile)"
    }
}

function Test-DaemonRunning {
    param([Parameter(Mandatory)][string]$ClientPath)

    & $ClientPath (Get-ServerArg $EmacsProfile) --eval '(emacs-pid)' 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Wait-ForDaemon {
    param([Parameter(Mandatory)][string]$ClientPath)

    # Daemons load deferred packages eagerly (Doom takes ~50s), so be patient.
    for ($attempt = 0; $attempt -lt 180; $attempt++) {
        if (Test-DaemonRunning -ClientPath $ClientPath) { return }
        Start-Sleep -Seconds 1
    }
    throw "Timed out waiting for Emacs profile '$EmacsProfile'."
}

function Start-Daemon {
    param(
        [Parameter(Mandatory)][string]$EmacsPath,
        [Parameter(Mandatory)][string]$ClientPath,
        [Parameter(Mandatory)][psobject]$ProfilePaths
    )

    # A daemon takes ~50s to answer, so a second caller (login shortcut plus a
    # Start menu link) would see it as stopped and start another. Serialize the
    # check-and-start per profile; the caller that waits finds it running.
    $mutexName = "Local\windots-emacs-daemon-$EmacsProfile"
    $startLock = [System.Threading.Mutex]::new($false, $mutexName)
    try {
        if (-not $startLock.WaitOne([TimeSpan]::FromSeconds(240))) {
            throw ('Timed out waiting for another start of Emacs profile ' +
                "'$EmacsProfile'.")
        }
    }
    catch [System.Threading.AbandonedMutexException] { }
    try {
        if (Test-DaemonRunning -ClientPath $ClientPath) {
            Write-Host "Emacs profile '$EmacsProfile' is already running."
            return
        }

        if ($null -ne $ProfilePaths.Local -and
            -not (Test-Path -LiteralPath $ProfilePaths.Local)) {
            New-Item -ItemType Directory -Path $ProfilePaths.Local -Force | Out-Null
        }

        Write-Log 'starting'
        $started = Get-Date
        Invoke-WithEnvironment $ProfilePaths.Environment {
            $daemon = @{
                FilePath = $EmacsPath
                ArgumentList = @(
                    "--daemon=$EmacsProfile"
                    "--init-directory=$($ProfilePaths.Framework)"
                )
                RedirectStandardError = Join-Path $logDir "emacs-$EmacsProfile.log"
                WindowStyle = 'Hidden'
            }
            Start-Process @daemon | Out-Null
        }

        Wait-ForDaemon -ClientPath $ClientPath
        Write-Log "running after $([int]((Get-Date) - $started).TotalSeconds)s"
    }
    finally {
        $startLock.ReleaseMutex()
        $startLock.Dispose()
    }
}

function Stop-Daemon {
    param([Parameter(Mandatory)][string]$ClientPath)

    if (-not (Test-DaemonRunning -ClientPath $ClientPath)) {
        Write-Host "Emacs profile '$EmacsProfile' is not running."
        return
    }

    & $ClientPath (Get-ServerArg $EmacsProfile) --eval '(kill-emacs)' 2>$null | Out-Null
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        if (-not (Test-DaemonRunning -ClientPath $ClientPath)) {
            Write-Log 'stopped'
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out stopping Emacs profile '$EmacsProfile'."
}

function Set-DefaultProfileStartup {
    $profileFile = Join-Path $roots.StateRoot 'default-profile'
    New-Item -ItemType Directory -Path $roots.StateRoot -Force | Out-Null
    Set-Content -LiteralPath $profileFile -Value $EmacsProfile -Encoding utf8 -NoNewline

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $template = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass ' +
    '-File "{1}" start {2}'
    $pwsh = (Get-Process -Id $PID).Path
    $commandLine = $template -f $pwsh, $PSCommandPath, $EmacsProfile
    $property = @{
        Path = $runKey
        Name = 'EmacsDaemon'
        Value = $commandLine
        PropertyType = 'String'
        Force = $true
    }
    New-ItemProperty @property | Out-Null
}

$profilePaths = Get-ProfilePaths -Name $EmacsProfile
Assert-ProfileInstalled -ProfilePaths $profilePaths
# The real emacs.exe: runemacs drops the daemon's stderr, and the scoop shim
# would stay running as its parent. WindowStyle Hidden keeps its console unseen.
$emacsPath = Join-Path $ScoopRoot 'apps\msys2\current\ucrt64\bin\emacs.exe'
if (-not (Test-Path -LiteralPath $emacsPath)) { throw "Emacs not found: $emacsPath" }
$clientPath = Get-RequiredCommand -Name 'emacsclient'
$startArgs = @{
    EmacsPath = $emacsPath
    ClientPath = $clientPath
    ProfilePaths = $profilePaths
}

# emacsclient runs $ALTERNATE_EDITOR (e.g. nvim) when no server answers, which
# turns every liveness probe into a hidden editor that never returns.
$savedAlternateEditor = $env:ALTERNATE_EDITOR
Remove-Item Env:ALTERNATE_EDITOR -ErrorAction SilentlyContinue
try {
    switch ($Action) {
        'switch' {
            foreach ($profileName in @('doom', 'spacemacs')) {
                if ($profileName -eq $EmacsProfile) { continue }
                $serverArg = Get-ServerArg $profileName
                & $clientPath $serverArg --eval '(kill-emacs)' 2>$null | Out-Null
            }
            Start-Daemon @startArgs
            Set-DefaultProfileStartup
        }
        'start' {
            Start-Daemon @startArgs
        }
        'stop' {
            Stop-Daemon -ClientPath $clientPath
        }
        'restart' {
            Stop-Daemon -ClientPath $clientPath
            Start-Daemon @startArgs
        }
        'open' {
            Start-Daemon @startArgs
            $serverArg = Get-ServerArg $EmacsProfile
            if ($EmacsClientArgs.Count -gt 0) {
                & $clientPath $serverArg --reuse-frame @EmacsClientArgs
            }
            else {
                & $clientPath $serverArg --create-frame
            }
            exit $LASTEXITCODE
        }
        'status' {
            if (Test-DaemonRunning -ClientPath $clientPath) {
                Write-Host "Emacs profile '$EmacsProfile' is running."
            }
            else {
                Write-Host "Emacs profile '$EmacsProfile' is stopped."
                exit 3
            }
        }
    }
}
finally {
    if ($null -ne $savedAlternateEditor) {
        $env:ALTERNATE_EDITOR = $savedAlternateEditor
    }
}
