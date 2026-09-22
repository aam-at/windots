<#
Links config files and folders from this repo and ~/dotfiles into place.

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

$RepoRoot = Split-Path -Parent $PSScriptRoot
function RepoPath([string]$Relative) { Join-Path $RepoRoot $Relative }

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
    ($PROFILE.CurrentUserAllHosts)                                                                            = (RepoPath 'scripts\Profile.ps1')
    (Join-Path $HOME 'bin\cc-personal.cmd')                                                                   = (RepoPath 'cmd\cc-personal.cmd')
    (Join-Path $HOME 'bin\cc-work.cmd')                                                                       = (RepoPath 'cmd\cc-work.cmd')
    (Join-Path $HOME '.config\kanata')                                                                        = (RepoPath 'kanata')
    (Join-Path $HOME '.config\komorebi')                                                                      = (RepoPath 'shells\komorebi')
    (Join-Path $env:APPDATA 'WindowsVirtualDesktopHelper\WindowsVirtualDesktopHelper.exe.config')             = (RepoPath 'shells\native\WindowsVirtualDesktopHelper.exe.config')
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\KeyboardShortcuts\windots-native.yaml')                    = (RepoPath 'shells\native\windots-native.yaml')
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\KeyboardShortcuts\windots-komorebi.yaml')                  = (RepoPath 'shells\komorebi\windots-komorebi.yaml')
    (Join-Path $HOME '.config\wezterm')                                                                       = (Join-Path $HOME 'dotfiles\config\wezterm')
    (Join-Path $HOME '.config\yasb')                                                                          = (RepoPath 'yasb')
    (Join-Path $HOME '.gitconfig')                                                                            = (RepoPath 'git\config')
    (Join-Path $HOME '.ideavimrc')                                                                            = (Join-Path $HOME 'dotfiles\idea\ideavimrc')
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json') = (RepoPath 'terminal\settings.json')
    (Join-Path $env:LOCALAPPDATA 'direnv')                                                                    = (Join-Path $HOME 'dotfiles\config\direnv')
    (Join-Path $env:LOCALAPPDATA 'fastfetch')                                                                 = (RepoPath 'fastfetch')
    (Join-Path $env:LOCALAPPDATA 'lazygit')                                                                   = (Join-Path $HOME 'dotfiles\config\lazygit')
    (Join-Path $HOME '.config\starship.toml')                                                                 = (Join-Path $HOME 'dotfiles\config\starship.toml')
    (Join-Path $HOME '.config\theme')                                                                         = (Join-Path $HOME 'dotfiles\themes\gruvbox-dark')
    (Join-Path $HOME '.claude\settings.json')                                                                 = (Join-Path $HOME 'dotfiles\config\agents\claude\settings.json')
    (Join-Path $HOME '.codex\config.toml')                                                                    = (Join-Path $HOME 'dotfiles\config\agents\codex\config.toml')
    (Join-Path $env:LOCALAPPDATA 'nvim')                                                                      = (Join-Path $HOME 'dotfiles\config\lazyvim')
    (Join-Path $env:LOCALAPPDATA 'television\config\config.toml')                                             = (Join-Path $HOME 'dotfiles\config\television\config.toml')
    (Join-Path $env:APPDATA 'gitu')                                                                           = (Join-Path $HOME 'dotfiles\config\gitu')
    (Join-Path $env:APPDATA 'gitui')                                                                          = (Join-Path $HOME 'dotfiles\config\gitui')
    (Join-Path $env:APPDATA 'helix')                                                                          = (Join-Path $HOME 'dotfiles\config\helix')
    (Join-Path $env:APPDATA 'yazi\config')                                                                    = (Join-Path $HOME 'dotfiles\config\yazi')
    (Join-Path $env:APPDATA 'Zed')                                                                            = (Join-Path $HOME 'dotfiles\config\zed')
    (Join-Path $HOME '.config\emacs\doom')                                                                    = (Join-Path $HOME 'dotfiles\emacs\doom')
    (Join-Path $HOME '.config\emacs\config')                                                                  = (Join-Path $HOME 'dotfiles\emacs\config')
    (Join-Path $HOME '.config\emacs\funcs')                                                                   = (Join-Path $HOME 'dotfiles\emacs\funcs')
    (Join-Path $HOME '.config\emacs\spacemacs')                                                               = (Join-Path $HOME 'dotfiles\emacs\spacemacs')
    (Join-Path $HOME '.config\emacs\spacemacs-full\config')                                                   = (Join-Path $HOME 'dotfiles\emacs\config')
    (Join-Path $HOME '.config\emacs\spacemacs-full\funcs')                                                    = (Join-Path $HOME 'dotfiles\emacs\funcs')
    (Join-Path $HOME '.config\emacs\spacemacs-full\layers')                                                   = (Join-Path $HOME 'dotfiles\emacs\spacemacs')
    (Join-Path $HOME '.config\emacs\spacemacs-full\init.el')                                                  = (Join-Path $HOME 'dotfiles\emacs\spacemacs\spacemacs_full')
    (Join-Path $HOME '.config\emacs\spacemacs-basic\init.el')                                                 = (Join-Path $HOME 'dotfiles\emacs\spacemacs\spacemacs_basic')
    (Join-Path $HOME '.config\emacs\spacemacs-writing\config')                                                = (Join-Path $HOME 'dotfiles\emacs\config')
    (Join-Path $HOME '.config\emacs\spacemacs-writing\funcs')                                                 = (Join-Path $HOME 'dotfiles\emacs\funcs')
    (Join-Path $HOME '.config\emacs\spacemacs-writing\layers')                                                = (Join-Path $HOME 'dotfiles\emacs\spacemacs')
    (Join-Path $HOME '.config\emacs\spacemacs-writing\init.el')                                               = (Join-Path $HOME 'dotfiles\emacs\spacemacs\spacemacs_writing')
}

$windowsPowerShellProfile = Join-Path $HOME 'Documents\WindowsPowerShell\profile.ps1'
if ($PROFILE.CurrentUserAllHosts -ne $windowsPowerShellProfile) {
    $linkMap[$windowsPowerShellProfile] = RepoPath 'scripts\Profile.ps1'
}

try {
    foreach ($link in $linkMap.GetEnumerator()) { Ensure-Link $link.Key $link.Value }
}
catch {
    Write-Error $_
    exit 1
}
