<#
============================================================
 Windows Setup Script
============================================================
#>

# Enable strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "Installing applications via Winget..."
Start-Process "winget" -ArgumentList "install --scope machine Git.Git HandBrake.HandBrake Helix.Helix Hunspell Neovim.Neovim Notepad++ OpenJS.NodeJS.LTS vim.vim winfsp VideoLAN.VLC Ghisler.TotalCommander Microsoft.Sysinternals.Suite MSYS2.MSYS2 GnuPG.GnuPG GnuPG.Gpg4win FarManager.FarManager qtpass Dropbox.Dropbox Google.Chrome Microsoft.VisualStudioCode Microsoft.PowerToys Microsoft.WindowsTerminal Microsoft.PowerShell" -Verb RunAs

Write-Host "Installing Scoop applications..."
scoop bucket add extras | Out-Null
scoop install extras/emacs extras/yasb extras/kanata extras/komorebi extras/komokana extras/winrar extras/autohotkey extras/activitywatch extras/mupdf
scoop install main/aspell main/gitui main/fd main/fzf main/direnv main/wget main/yazi main/ripgrep main/ffmpeg main/delta main/gzip main/curl main/starship main/7zip main/yt-dlp main/bat main/ag main/sqlite main/tectonic main/texlab main/fastfetch main/sed
Write-Host "Applications installation complete.`n"

# ================================================================
#  Variables
# ================================================================
$CONFIG = Join-Path $HOME ".config"
$TOOLS  = Join-Path $HOME "local\tools"

git clone https://github.com/aam-at/spacemacs $env:APPDATA/.emacs.d

# ================================================================
#  Create symbolic and junction links
# ================================================================

$symlinks = @{
    $PROFILE.CurrentUserAllHosts                                                                    = ".\Profile.ps1"
    "$HOME\.gitconfig"                                                                              = ".\git\config"
    "$HOME\.ideavimrc" = "$HOME\dotfiles\idea\ideavimrc"
    "$HOME\.spacemacs.d\init.el" = "$HOME\dotfiles\spacemacs\spacemacs_full"
    "$HOME\.spacemacs.d\config" = "$HOME\dotfiles\spacemacs\config"
    "$env:LOCALAPPDATA\nvim"                                                                      = "$HOME\dotfiles\config\lazyvim"
    "$env:LOCALAPPDATA\direnv"                                                                      = "$HOME\dotfiles\config\direnv"
    "$env:LOCALAPPDATA\fastfetch"                                                                 = ".\fastfetch"
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json" = ".\terminal\settings.json"
    "$env:LOCALAPPDATA\lazygit"                                                                 = "$HOME\dotfiles\config\lazygit"
    "$env:APPDATA\helix" = "$HOME\dotfiles\config\helix"
    "$env:APPDATA\yazi" = "$HOME\dotfiles\config\yazi"
    "$env:APPDATA\gitui" = "$HOME\dotfiles\config\gitui"
}

# Create Symbolic Links
Write-Host "Creating Symbolic Links..."
foreach ($symlink in $symlinks.GetEnumerator()) {
	echo $symlink.Key
	echo $symlink.Value
    Get-Item -Path $symlink.Key -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    New-Item -ItemType SymbolicLink -Path $symlink.Key -Target (Resolve-Path $symlink.Value) -Force | Out-Null
}

Write-Host "Script completed successfully."
Pause
