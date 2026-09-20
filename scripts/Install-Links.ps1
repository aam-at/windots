<#
Creates the Windows dotfile links and Startup-folder shortcuts.

Usage:
  pwsh -File .\scripts\Install-Links.ps1
  pwsh -File .\scripts\Install-Links.ps1 -Force
  pwsh -File .\scripts\Install-Links.ps1 -DryRun
  pwsh -File .\scripts\Install-Links.ps1 -DesktopMode Native
#>

param(
    [switch]$SkipConfigLinks,
    [switch]$SkipStartupLinks,
    [switch]$DryRun,
    [switch]$Force,
    [ValidateSet('Native', 'Komorebi')]
    [string]$DesktopMode = 'Native',
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot
function RepoPath([string]$Relative) { Join-Path $RepoRoot $Relative }

function Remove-PathSafe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    $item = Get-Item -LiteralPath $Path -Force
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

    if ((Test-Path -LiteralPath $Destination) -and -not (Remove-PathSafe $Destination)) { return }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        Write-Info "Creating parent directory: $parent"
        if (-not $DryRun) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }

    if (Test-Path -LiteralPath $sourcePath -PathType Container) { New-DirectoryLink $Destination $sourcePath }
    else { New-FileLink $Destination $sourcePath }
}

function Resolve-Executable([string[]]$Candidates) {
    foreach ($candidate in $Candidates) {
        if ([System.IO.Path]::IsPathRooted($candidate)) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            continue
        }
        $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
}

function Resolve-KanataGui {
    # Scoop's kanata package only shims the console (tty) build; the tray-icon
    # (gui) build sits unshimmed in the app folder, so PATH lookup can't find it.
    $scoopRoot = if ([string]::IsNullOrWhiteSpace($env:SCOOP)) { Join-Path $HOME 'scoop' } else { $env:SCOOP }
    $kanataAppRoot = Join-Path $scoopRoot 'apps\kanata\current'
    Get-ChildItem -LiteralPath $kanataAppRoot -Filter 'kanata_windows_gui_winIOv2_*.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*cmd_allowed*' } |
        Select-Object -First 1 -ExpandProperty FullName
}

function Ensure-StartupShortcut {
    param(
        [string]$Name,
        [string[]]$Candidates,
        [string]$Arguments,
        [string]$RunningProcessName
    )

    $target = Resolve-Executable $Candidates
    if (-not $target) {
        Write-Warn "$Name executable not found on PATH; skipping Startup shortcut."
        return $false
    }

    $startupDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    $shortcutPath = Join-Path $startupDirectory "$Name.lnk"
    Write-Info "Creating Startup shortcut: $shortcutPath"
    if ($DryRun) { return $true }

    New-Shortcut -Path $shortcutPath -Target $target -Arguments $Arguments -WorkingDirectory (Split-Path -Parent $target)

    # Start it now too, so setup doesn't require a reboot to see it running.
    $processName = if ($RunningProcessName) { $RunningProcessName } else { [System.IO.Path]::GetFileNameWithoutExtension($target) }
    if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
        Write-Info "$Name is already running."
    }
    else {
        Write-Info "Starting $Name..."
        if ([string]::IsNullOrWhiteSpace($Arguments)) {
            Start-Process -FilePath $target -WorkingDirectory (Split-Path -Parent $target) | Out-Null
        }
        else {
            Start-Process -FilePath $target -ArgumentList $Arguments -WorkingDirectory (Split-Path -Parent $target) | Out-Null
        }
    }
    return $true
}

function Remove-LegacyStartupEntry([string]$Name) {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Get-ItemProperty -Path $runKey -Name $Name -ErrorAction SilentlyContinue)) { return }

    Write-Info "Removing legacy Registry startup entry: $Name"
    if (-not $DryRun) { Remove-ItemProperty -Path $runKey -Name $Name -ErrorAction Stop }
}

function Remove-StartupShortcut([string]$Name) {
    $startupDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    $path = Join-Path $startupDirectory "$Name.lnk"
    if (-not (Test-Path -LiteralPath $path)) { return }

    Write-Info "Removing Startup shortcut: $path"
    if (-not $DryRun) { Remove-Item -LiteralPath $path -Force }
}

$linkMap = @{
    ($PROFILE.CurrentUserAllHosts)                                                                            = (RepoPath 'scripts\Profile.ps1')
    (Join-Path $HOME 'bin\cc-personal.cmd')                                                                   = (RepoPath 'cmd\cc-personal.cmd')
    (Join-Path $HOME 'bin\cc-work.cmd')                                                                       = (RepoPath 'cmd\cc-work.cmd')
    (Join-Path $HOME '.config\kanata')                                                                        = (RepoPath 'kanata')
    (Join-Path $HOME '.config\komorebi')                                                                      = (RepoPath 'komorebi')
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
    if (-not $SkipConfigLinks) {
        foreach ($link in $linkMap.GetEnumerator()) { Ensure-Link $link.Key $link.Value }
    }

    if (-not $SkipStartupLinks) {
        if ($DesktopMode -eq 'Komorebi') {
            # --ahk is end-of-life in komorebic (not in `komorebic start --help`
            # any more): it prints a deprecation notice and never actually starts
            # AutoHotkey, so we launch it ourselves against the real script path.
            Remove-StartupShortcut 'NativeDesktop'
            $komorebiConfig = Join-Path $HOME '.config\komorebi\komorebi.json'
            $komorebiArguments = 'start --clean-state --config "{0}"' -f $komorebiConfig
            if (Ensure-StartupShortcut -Name 'Komorebi' -Candidates @('komorebic-no-console', 'komorebic') -Arguments $komorebiArguments -RunningProcessName 'komorebi') {
                Remove-LegacyStartupEntry 'Komorebic'
            }
            $komorebiAhk = Join-Path $HOME '.config\komorebi\komorebi.ahk'
            if (Test-Path -LiteralPath $komorebiAhk) {
                [void](Ensure-StartupShortcut -Name 'KomorebiAHK' -Candidates @('autohotkey', 'AutoHotkey64', 'AutoHotkey') -Arguments ('"{0}"' -f $komorebiAhk) -RunningProcessName 'AutoHotkeyUX')
            }
            else {
                Write-Warn "komorebi.ahk not found at $komorebiAhk; skipping AutoHotkey startup shortcut."
            }
        }
        else {
            Remove-StartupShortcut 'Komorebi'
            Remove-StartupShortcut 'KomorebiAHK'
            $nativeDesktop = Join-Path $PSScriptRoot 'Native-Desktop.ahk'
            if (Test-Path -LiteralPath $nativeDesktop) {
                [void](Ensure-StartupShortcut -Name 'NativeDesktop' -Candidates @('autohotkey', 'AutoHotkey64', 'AutoHotkey') -Arguments ('"{0}"' -f $nativeDesktop) -RunningProcessName 'AutoHotkeyUX')
            }
            else {
                Write-Warn "Native desktop bindings not found at $nativeDesktop; skipping AutoHotkey startup shortcut."
            }
        }
        if (Ensure-StartupShortcut -Name 'YASB' -Candidates @('yasb', 'yasb.exe') -Arguments '') {
            Remove-LegacyStartupEntry 'YASB'
        }
        $kanataConfig = Join-Path $HOME '.config\kanata\config.kbd'
        $kanataCandidates = @(Resolve-KanataGui) + @('kanata_gui', 'kanata-gui', 'kanata') | Where-Object { $_ }
        if (Ensure-StartupShortcut -Name 'Kanata' -Candidates $kanataCandidates -Arguments ('-c "{0}"' -f $kanataConfig)) {
            Remove-LegacyStartupEntry 'Kanata'
        }
    }
}
catch {
    Write-Error $_
    exit 1
}
