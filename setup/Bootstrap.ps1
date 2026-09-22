<#
Fresh-machine entry point: installs Scoop and Git, clones this repo, then
hands off to Setup.ps1. Setup.ps1 expects Scoop and Git already on PATH and
clones the shared ~/dotfiles repo itself.

Usage (fresh Windows box, from a regular PowerShell prompt):
  irm https://raw.githubusercontent.com/aam-at/windots/master/setup/Bootstrap.ps1 | iex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BootstrapUrl = 'https://raw.githubusercontent.com/aam-at/windots/master/setup/Bootstrap.ps1'

function Test-Command($name) { $null -ne (Get-Command $name -ErrorAction SilentlyContinue) }

if (-not (Test-Command 'scoop')) {
    Write-Host '[INFO] Installing Scoop...'
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Invoke-RestMethod -Uri 'https://get.scoop.sh' | Invoke-Expression

    # get.scoop.sh only updates the User PATH registry value; a brand new
    # process picks that up cleanly, so reopen a shell instead of patching
    # $env:PATH by hand.
    Write-Host '[INFO] Reopening a shell so Scoop is on PATH...'
    $hostExe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "irm $BootstrapUrl | iex") -Wait -NoNewWindow
    exit $LASTEXITCODE
}

if (-not (Test-Command 'git')) {
    Write-Host '[INFO] Installing Git via Scoop...'
    scoop install git
}

$windotsRoot = Join-Path $HOME 'windots'
if (-not (Test-Path -LiteralPath (Join-Path $windotsRoot '.git'))) {
    Write-Host '[INFO] Cloning windots...'
    git clone https://github.com/aam-at/windots.git $windotsRoot
}

Write-Host '[INFO] Running Setup.ps1...'
& (Join-Path $windotsRoot 'setup\Setup.ps1')
