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
    [ValidateSet('doom', 'spacemacs-full', 'spacemacs-basic', 'spacemacs-writing')]
    [string]$EmacsProfile,

    [Parameter(Position = 2, ValueFromRemainingArguments = $true)]
    [string[]]$EmacsClientArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\setup\Common.ps1')
$roots = Get-EmacsRoots
$configRoot = $roots.ConfigRoot
$dataRoot = $roots.DataRoot
$stateRoot = $roots.StateRoot

function Get-RequiredCommand {
    param([Parameter(Mandatory)][string]$Name)

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command not found on PATH: $Name"
    }
    return $command.Source
}

function Get-ProfilePaths {
    param([Parameter(Mandatory)][string]$Name)

    switch ($Name) {
        'doom' {
            return [pscustomobject]@{
                Framework   = Join-Path $dataRoot 'doom'
                Profile     = Join-Path $configRoot 'doom'
                Local       = Join-Path $stateRoot 'doom'
                Environment = @{
                    EMACSDIR     = (Join-Path $dataRoot 'doom')
                    DOOMDIR      = (Join-Path $configRoot 'doom')
                    DOOMLOCALDIR = (Join-Path $stateRoot 'doom')
                }
            }
        }
        default {
            return [pscustomobject]@{
                Framework   = Join-Path $dataRoot 'spacemacs'
                Profile     = Join-Path $configRoot $Name
                Local       = $null
                Environment = @{ SPACEMACSDIR = (Join-Path $configRoot $Name) }
            }
        }
    }
}

function Assert-ProfileInstalled {
    param([Parameter(Mandatory)][psobject]$ProfilePaths)

    if (-not (Test-Path -LiteralPath (Join-Path $ProfilePaths.Framework 'init.el'))) {
        throw "Emacs framework is not installed at $($ProfilePaths.Framework)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ProfilePaths.Profile 'init.el'))) {
        throw "Emacs profile is not installed at $($ProfilePaths.Profile)"
    }
}

function Test-DaemonRunning {
    param([Parameter(Mandatory)][string]$ClientPath)

    & $ClientPath "--socket-name=$EmacsProfile" --eval '(emacs-pid)' 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Wait-ForDaemon {
    param([Parameter(Mandatory)][string]$ClientPath)

    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        if (Test-DaemonRunning -ClientPath $ClientPath) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for Emacs profile '$EmacsProfile'."
}

function Start-Daemon {
    param(
        [Parameter(Mandatory)][string]$EmacsPath,
        [Parameter(Mandatory)][string]$ClientPath,
        [Parameter(Mandatory)][psobject]$ProfilePaths
    )

    if (Test-DaemonRunning -ClientPath $ClientPath) {
        Write-Host "Emacs profile '$EmacsProfile' is already running."
        return
    }

    if ($null -ne $ProfilePaths.Local -and -not (Test-Path -LiteralPath $ProfilePaths.Local)) {
        New-Item -ItemType Directory -Path $ProfilePaths.Local -Force | Out-Null
    }

    $savedEnvironment = @{}
    try {
        foreach ($name in $ProfilePaths.Environment.Keys) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            Set-Item -Path "Env:$name" -Value $ProfilePaths.Environment[$name]
        }

        Start-Process -FilePath $EmacsPath -ArgumentList @("--daemon=$EmacsProfile", "--init-directory=$($ProfilePaths.Framework)") | Out-Null
    }
    finally {
        foreach ($name in $ProfilePaths.Environment.Keys) {
            $previousValue = $savedEnvironment[$name]
            if ($null -eq $previousValue) { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue }
            else { Set-Item -Path "Env:$name" -Value $previousValue }
        }
    }

    Wait-ForDaemon -ClientPath $ClientPath
}

function Stop-Daemon {
    param([Parameter(Mandatory)][string]$ClientPath)

    if (-not (Test-DaemonRunning -ClientPath $ClientPath)) {
        Write-Host "Emacs profile '$EmacsProfile' is not running."
        return
    }

    & $ClientPath "--socket-name=$EmacsProfile" --eval '(kill-emacs)' | Out-Null
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        if (-not (Test-DaemonRunning -ClientPath $ClientPath)) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out stopping Emacs profile '$EmacsProfile'."
}

function Set-DefaultProfileStartup {
    $profileFile = Join-Path $stateRoot 'default-profile'
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
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

switch ($Action) {
    'switch' {
        foreach ($profileName in @('doom', 'spacemacs-full', 'spacemacs-basic', 'spacemacs-writing')) {
            if ($profileName -eq $EmacsProfile) { continue }
            & $clientPath "--socket-name=$profileName" --eval '(kill-emacs)' 2>$null | Out-Null
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
            & $clientPath "--socket-name=$EmacsProfile" --reuse-frame @EmacsClientArgs
        }
        else {
            & $clientPath "--socket-name=$EmacsProfile" --create-frame
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
