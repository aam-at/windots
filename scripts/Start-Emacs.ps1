<#
Starts an Emacs daemon at Windows logon. Point a Startup-folder shortcut at
this script (see Install-Links.ps1) to bring the daemon up automatically.

Usage:
  pwsh -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File Start-Emacs.ps1 -EmacsProfile doom
#>

param(
    [ValidateSet('doom', 'spacemacs-full', 'spacemacs-basic', 'spacemacs-writing')]
    [string]$EmacsProfile = 'doom'
)

& (Join-Path $PSScriptRoot 'Emacs-Daemon.ps1') start $EmacsProfile
exit $LASTEXITCODE
