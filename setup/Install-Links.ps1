<#
Links config files and folders from this repo and the dotfiles checkout
($env:DOTFILES, default ~/dotfiles) into place.

Usage:
  pwsh -File .\setup\Install-Links.ps1
  pwsh -File .\setup\Install-Links.ps1 -Force
  pwsh -File .\setup\Install-Links.ps1 -DryRun
#>

param(
    [switch]$DryRun,
    [switch]$Force,
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$WindotsRoot = Split-Path -Parent $PSScriptRoot
function WindotsPath([string]$Relative) { Join-Path $WindotsRoot $Relative }
function DotfilesPath([string]$Relative) { Join-Path $DotfilesRoot $Relative }

function Remove-PathSafe([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $true }
    $isLink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if (-not $isLink -and -not $Force) {
        Write-Warn "Existing path is not a link; preserving it. Re-run with -Force to replace: $Path"
        return $false
    }

    Write-Info "Removing existing path: $Path"
    if (-not $DryRun) {
        if ($isLink) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        else { Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction Stop }
    }
    return $true
}

function New-FileLink([string]$Path, [string]$Target) {
    try {
        Write-Info "Creating file symlink: $Path -> $Target"
        if (-not $DryRun) { New-Item -ItemType SymbolicLink -Path $Path -Target $Target -Force | Out-Null }
    }
    catch {
        try {
            Write-Warn "Symlink failed; attempting hardlink: $Path -> $Target"
            if (-not $DryRun) { New-Item -ItemType HardLink -Path $Path -Target $Target -Force | Out-Null }
        }
        catch {
            Write-Warn "Hardlink failed; copying file: $Path <- $Target"
            if (-not $DryRun) { Copy-Item -LiteralPath $Target -Destination $Path -Force }
        }
    }
}

function New-DirectoryLink([string]$Path, [string]$Target) {
    try {
        Write-Info "Creating junction: $Path -> $Target"
        if (-not $DryRun) { New-Item -ItemType Junction -Path $Path -Target $Target -Force | Out-Null }
    }
    catch {
        Write-Warn "Junction failed; copying directory: $Path <- $Target"
        if (-not $DryRun) { Copy-Item -LiteralPath $Target -Destination $Path -Recurse -Force }
    }
}

function Ensure-Link([string]$Destination, [string]$Source) {
    try {
        $sourcePath = (Resolve-Path -LiteralPath $Source -ErrorAction Stop).ProviderPath
    }
    catch {
        Write-Warn "Target missing; skip link: $Source"
        return
    }

    if ((Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue) -and -not (Remove-PathSafe $Destination)) { return }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        Write-Info "Creating parent directory: $parent"
        if (-not $DryRun) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }

    if (Test-Path -LiteralPath $sourcePath -PathType Container) { New-DirectoryLink $Destination $sourcePath }
    else { New-FileLink $Destination $sourcePath }
}

$linkMap = @{
    ($PROFILE.CurrentUserAllHosts)                                                                            = (WindotsPath 'scripts\Profile.ps1')
    (Join-Path $HOME 'bin\cc-personal.cmd')                                                                   = (WindotsPath 'cmd\cc-personal.cmd')
    (Join-Path $HOME 'bin\cc-work.cmd')                                                                       = (WindotsPath 'cmd\cc-work.cmd')
    (Join-Path $HOME 'bin\herdr.cmd')                                                                         = (WindotsPath 'cmd\herdr.cmd')
    (Join-Path $env:LOCALAPPDATA 'clink\default_settings')                                                    = (WindotsPath 'clink\default_settings')
    (Join-Path $env:LOCALAPPDATA 'clink\_inputrc')                                                            = (WindotsPath 'clink\_inputrc')
    (Join-Path $env:LOCALAPPDATA 'clink\starship.lua')                                                        = (WindotsPath 'clink\starship.lua')
    (Join-Path $HOME '.config\kanata')                                                                        = (WindotsPath 'kanata')
    (Join-Path $HOME '.config\komorebi')                                                                      = (WindotsPath 'shells\komorebi')
    (Join-Path $env:APPDATA 'WindowsVirtualDesktopHelper\WindowsVirtualDesktopHelper.exe.config')             = (WindotsPath 'shells\native\WindowsVirtualDesktopHelper.exe.config')
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\KeyboardShortcuts\windots-native.yaml')                    = (WindotsPath 'shells\native\windots-native.yaml')
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\KeyboardShortcuts\windots-komorebi.yaml')                  = (WindotsPath 'shells\komorebi\windots-komorebi.yaml')
    (Join-Path $HOME '.config\wezterm')                                                                       = (DotfilesPath 'config\wezterm')
    (Join-Path $HOME '.config\yasb')                                                                          = (WindotsPath 'yasb')
    (Join-Path $HOME '.gitconfig')                                                                            = (WindotsPath 'git\config')
    (Join-Path $HOME '.ideavimrc')                                                                            = (DotfilesPath 'idea\ideavimrc')
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json') = (WindotsPath 'terminal\settings.json')
    (Join-Path $env:LOCALAPPDATA 'direnv')                                                                    = (DotfilesPath 'config\direnv')
    (Join-Path $env:LOCALAPPDATA 'fastfetch')                                                                 = (WindotsPath 'fastfetch')
    (Join-Path $env:LOCALAPPDATA 'lazygit')                                                                   = (DotfilesPath 'config\lazygit')
    (Join-Path $HOME '.config\starship.toml')                                                                 = (DotfilesPath 'config\starship.toml')
    (Join-Path $HOME '.config\theme')                                                                         = (DotfilesPath 'themes\gruvbox-dark')
    (Join-Path $HOME '.claude\settings.json')                                                                 = (DotfilesPath 'config\agents\claude\settings.json')
    (Join-Path $HOME '.codex\config.toml')                                                                    = (DotfilesPath 'config\agents\codex\config.toml')
    (Join-Path $env:LOCALAPPDATA 'nvim')                                                                      = (DotfilesPath 'config\lazyvim')
    (Join-Path $env:LOCALAPPDATA 'television\config\config.toml')                                             = (DotfilesPath 'config\television\config.toml')
    (Join-Path $env:APPDATA 'gitu')                                                                           = (DotfilesPath 'config\gitu')
    (Join-Path $env:APPDATA 'gitui')                                                                          = (DotfilesPath 'config\gitui')
    (Join-Path $env:APPDATA 'helix')                                                                          = (DotfilesPath 'config\helix')
    (Join-Path $env:APPDATA 'herdr\config.toml')                                                              = (DotfilesPath 'config\herdr\config.toml')
    (Join-Path $env:APPDATA 'yazi\config')                                                                    = (DotfilesPath 'config\yazi')
    (Join-Path $env:APPDATA 'Zed')                                                                            = (DotfilesPath 'config\zed')
    (Join-Path $HOME '.config\emacs\doom')                                                                    = (DotfilesPath 'emacs\doom')
    (Join-Path $HOME '.config\emacs\config')                                                                  = (DotfilesPath 'emacs\config')
    (Join-Path $HOME '.config\emacs\funcs')                                                                   = (DotfilesPath 'emacs\funcs')
    (Join-Path $HOME '.config\emacs\local')                                                                   = (DotfilesPath 'emacs\local')
    (Join-Path $HOME '.config\emacs\spacemacs\config')                                                        = (DotfilesPath 'emacs\config')
    (Join-Path $HOME '.config\emacs\spacemacs\funcs')                                                         = (DotfilesPath 'emacs\funcs')
    (Join-Path $HOME '.config\emacs\spacemacs\layers')                                                        = (DotfilesPath 'emacs\spacemacs')
    (Join-Path $HOME '.config\emacs\spacemacs\init.el')                                                       = (DotfilesPath 'emacs\spacemacs\init.el')
}

$windowsPowerShellProfile = Join-Path $HOME 'Documents\WindowsPowerShell\profile.ps1'
if ($PROFILE.CurrentUserAllHosts -ne $windowsPowerShellProfile) {
    $linkMap[$windowsPowerShellProfile] = WindotsPath 'scripts\Profile.ps1'
}

try {
    foreach ($link in $linkMap.GetEnumerator()) { Ensure-Link $link.Key $link.Value }
}
catch {
    Write-Error $_
    exit 1
}
