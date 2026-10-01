<#
Manage named Emacs daemons for the profiles in the shared dotfiles repository.

Usage:
  .\Emacs-Daemon.ps1 {switch|start|stop|restart|open|status} PROFILE [EMACSCLIENT-ARG ...]
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
    if (-not (@('init.el', 'early-init.el') | Where-Object { Test-Path -LiteralPath (Join-Path $ProfilePaths.Framework $_) })) {
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
    $startLock = [System.Threading.Mutex]::new($false, "Local\windots-emacs-daemon-$EmacsProfile")
    try {
        if (-not $startLock.WaitOne([TimeSpan]::FromSeconds(240))) {
            throw "Timed out waiting for another start of Emacs profile '$EmacsProfile'."
        }
    }
    catch [System.Threading.AbandonedMutexException] { }
    try {
        if (Test-DaemonRunning -ClientPath $ClientPath) {
            Write-Host "Emacs profile '$EmacsProfile' is already running."
            return
        }

        if ($null -ne $ProfilePaths.Local -and -not (Test-Path -LiteralPath $ProfilePaths.Local)) {
            New-Item -ItemType Directory -Path $ProfilePaths.Local -Force | Out-Null
        }

        Invoke-WithEnvironment $ProfilePaths.Environment {
            Start-Process -FilePath $EmacsPath -ArgumentList @("--daemon=$EmacsProfile", "--init-directory=$($ProfilePaths.Framework)") | Out-Null
        }

        Wait-ForDaemon -ClientPath $ClientPath
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
        if (-not (Test-DaemonRunning -ClientPath $ClientPath)) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out stopping Emacs profile '$EmacsProfile'."
}

function Set-DefaultProfileStartup {
    $profileFile = Join-Path $roots.StateRoot 'default-profile'
    New-Item -ItemType Directory -Path $roots.StateRoot -Force | Out-Null
    Set-Content -LiteralPath $profileFile -Value $EmacsProfile -Encoding utf8 -NoNewline

    $shellPath = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $shellPath) { $shellPath = Get-Command powershell -CommandType Application -ErrorAction Stop }

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $commandLine = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" start {2}' -f $shellPath.Source, $PSCommandPath, $EmacsProfile
    New-ItemProperty -Path $runKey -Name 'EmacsDaemon' -Value $commandLine -PropertyType String -Force | Out-Null
}

$profilePaths = Get-ProfilePaths -Name $EmacsProfile
Assert-ProfileInstalled -ProfilePaths $profilePaths
$emacsPath = Get-RequiredCommand -Name 'emacs'
$clientPath = Get-RequiredCommand -Name 'emacsclient'

# emacsclient runs $ALTERNATE_EDITOR (e.g. nvim) when no server answers, which
# turns every liveness probe into a hidden editor that never returns.
$savedAlternateEditor = $env:ALTERNATE_EDITOR
Remove-Item Env:ALTERNATE_EDITOR -ErrorAction SilentlyContinue
try {
    switch ($Action) {
        'switch' {
            foreach ($profileName in @('doom', 'spacemacs')) {
                if ($profileName -eq $EmacsProfile) { continue }
                & $clientPath (Get-ServerArg $profileName) --eval '(kill-emacs)' 2>$null | Out-Null
            }
            Start-Daemon -EmacsPath $emacsPath -ClientPath $clientPath -ProfilePaths $profilePaths
            Set-DefaultProfileStartup
        }
        'start' {
            Start-Daemon -EmacsPath $emacsPath -ClientPath $clientPath -ProfilePaths $profilePaths
        }
        'stop' {
            Stop-Daemon -ClientPath $clientPath
        }
        'restart' {
            Stop-Daemon -ClientPath $clientPath
            Start-Daemon -EmacsPath $emacsPath -ClientPath $clientPath -ProfilePaths $profilePaths
        }
        'open' {
            Start-Daemon -EmacsPath $emacsPath -ClientPath $clientPath -ProfilePaths $profilePaths
            if ($EmacsClientArgs.Count -gt 0) {
                & $clientPath (Get-ServerArg $EmacsProfile) --reuse-frame @EmacsClientArgs
            }
            else {
                & $clientPath (Get-ServerArg $EmacsProfile) --create-frame
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
    if ($null -ne $savedAlternateEditor) { $env:ALTERNATE_EDITOR = $savedAlternateEditor }
}
