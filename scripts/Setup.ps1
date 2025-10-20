<#
=================================================================
 Windows Setup Script (refactored)
 - Installs common tools (winget / scoop)
 - Creates idempotent links to config files and folders
 - Safer fallbacks for link creation (junction/hardlink/copy)
 Usage examples:
   pwsh -ExecutionPolicy Bypass -File .\scripts\Setup.ps1
   pwsh -File .\scripts\Setup.ps1 -SkipPackages
   pwsh -File .\scripts\Setup.ps1 -DryRun
=================================================================
#>

param(
    [switch]$SkipPackages,
    [switch]$SkipLinks,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$InstallSpacemacs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err ($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Test-IsAdmin {
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-Command($name) { $null -ne (Get-Command $name -ErrorAction SilentlyContinue) }

function Invoke-IfNotDryRun {
    param([scriptblock]$Action)
    if ($DryRun) { return } else { & $Action }
}

# Resolve repo root regardless of invocation CWD
$RepoRoot = Split-Path -Parent $PSScriptRoot
function RepoPath([string]$Relative) { return (Join-Path $RepoRoot $Relative) }

# -----------------------
# Package Installation
# -----------------------
function Install-Packages {
    if ($SkipPackages) { Write-Info 'Skipping package installation.'; return }

    # Winget apps (install per-ID for clearer output and retries)
    $wingetApps = @(
        'Dropbox.Dropbox', 'FarManager.FarManager', 'Ghisler.TotalCommander', 'Git.Git', 'GnuPG.GnuPG',
        'GnuPG.Gpg4win', 'Google.Chrome', 'HandBrake.HandBrake', 'Helix.Helix', 'Hunspell', 'MSYS2.MSYS2',
        'Microsoft.PowerShell', 'Microsoft.PowerToys', 'Microsoft.Sysinternals.Suite', 'Microsoft.VisualStudioCode',
        'Microsoft.WindowsTerminal', 'Neovim.Neovim', 'Notepad++', 'OpenJS.NodeJS.LTS', 'VideoLAN.VLC',
        'qtpass', 'vim.vim', 'winfsp'
    )

    if (Test-Command 'winget') {
        Write-Info 'Installing applications via winget...'
        foreach ($id in $wingetApps) {
            Write-Info "winget install -e --scope machine --id $id"
            Invoke-IfNotDryRun { winget install -e --scope machine --id $id --silent --accept-source-agreements --accept-package-agreements } | Out-Null
        }
    } else {
        Write-Warn 'winget not found; skipping winget apps.'
    }

    # Scoop apps and buckets
    $scoopBuckets = @('extras')
    $scoopApps1   = @('activitywatch', 'autohotkey', 'emacs', 'kanata', 'komokana', 'komorebi', 'lua', 'mupdf', 'winrar', 'yasb')
    $scoopApps2   = @('7zip', 'ag', 'aspell', 'bat', 'curl', 'delta', 'direnv', 'fastfetch', 'fd', 'ffmpeg', 'fzf', 'gitui', 'gzip', 'ripgrep', 'sed', 'sqlite', 'starship', 'tectonic', 'texlab', 'wget', 'yazi', 'yt-dlp')

    if (Test-Command 'scoop') {
        Write-Info 'Ensuring scoop buckets and apps are installed...'
        foreach ($b in $scoopBuckets) {
            Write-Info "scoop bucket add $b"
            Invoke-IfNotDryRun { scoop bucket add $b } | Out-Null
        }
        if ($scoopApps1.Count -gt 0) {
            Write-Info ("scoop install " + ($scoopApps1 -join ' '))
            Invoke-IfNotDryRun { scoop install $scoopApps1 } | Out-Null
        }
        if ($scoopApps2.Count -gt 0) {
            Write-Info ("scoop install " + ($scoopApps2 -join ' '))
            Invoke-IfNotDryRun { scoop install $scoopApps2 } | Out-Null
        }
    } else {
        Write-Warn 'scoop not found; skipping scoop apps.'
    }

    if ($InstallSpacemacs) {
        if (-not (Test-Command 'git')) { Write-Warn 'git not found; skip Spacemacs clone.' }
        else {
            $dest = Join-Path $env:APPDATA '.emacs.d'
            if (-not (Test-Path -LiteralPath $dest)) {
                Write-Info "Cloning Spacemacs to $dest"
                Invoke-IfNotDryRun { git clone https://github.com/aam-at/spacemacs $dest }
            } else { Write-Info "Spacemacs already present at $dest" }
        }
    }

    Write-Info 'Package installation step complete.'
}

# -----------------------
# PowerShell Modules
# -----------------------
function Install-PowerShellModules {
    if ($SkipPackages) { return }
    if (-not (Test-Command Install-Module)) { Write-Warn 'Install-Module not available; skipping PS module installs.'; return }

    $psModules = @(
        'CompletionPredictor',
        'PSScriptAnalyzer'
    )

    try {
        $repo = Get-PSRepository -Name 'PSGallery' -ErrorAction Stop
        if ($repo.InstallationPolicy -ne 'Trusted') {
            Write-Info 'Trusting PSGallery repository'
            Invoke-IfNotDryRun { Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted }
        }
    } catch {
        Write-Warn 'PSGallery repository not found or PowerShellGet not loaded.'
    }

    foreach ($psModule in $psModules) {
        if (-not (Get-Module -ListAvailable -Name $psModule)) {
            Write-Info "Installing PS module: $psModule"
            Invoke-IfNotDryRun { Install-Module -Name $psModule -Force -AcceptLicense -Scope CurrentUser -Repository PSGallery }
        } else {
            Write-Info "PS module already available: $psModule"
        }
    }
}

# -----------------------
# Link Helpers
# -----------------------
function Remove-PathSafe($path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    Write-Info "Removing existing path: $path"
    Invoke-IfNotDryRun { Remove-Item -LiteralPath $path -Force -Recurse -ErrorAction SilentlyContinue }
}

function New-FileLink($path, $target) {
    try {
        Write-Info "Creating file symlink: $path -> $target"
        Invoke-IfNotDryRun { New-Item -ItemType SymbolicLink -Path $path -Target $target -Force | Out-Null }
    } catch {
        try {
            Write-Warn "Symlink failed; attempting hardlink: $path -> $target"
            Invoke-IfNotDryRun { New-Item -ItemType HardLink -Path $path -Target $target -Force | Out-Null }
        } catch {
            Write-Warn "Hardlink failed; copying file: $path <- $target"
            Invoke-IfNotDryRun { Copy-Item -LiteralPath $target -Destination $path -Force }
        }
    }
}

function New-DirectoryLink($path, $target) {
    try {
        Write-Info "Creating junction: $path -> $target"
        Invoke-IfNotDryRun { New-Item -ItemType Junction -Path $path -Target $target -Force | Out-Null }
    } catch {
        Write-Warn "Junction failed; copying directory: $path <- $target"
        Invoke-IfNotDryRun { Copy-Item -LiteralPath $target -Destination $path -Recurse -Force }
    }
}

function Ensure-Link($dest, $src) {
    # Resolve and validate source
    try {
        $resolved = Resolve-Path -LiteralPath $src -ErrorAction Stop
        $srcPath = $resolved.ProviderPath
    } catch {
        Write-Warn "Target missing; skip link: $src"
        return
    }

    if (Test-Path -LiteralPath $dest) {
        Remove-PathSafe $dest
    }

    $srcIsDir = (Test-Path -LiteralPath $srcPath -PathType Container)
    $destParent = Split-Path -Parent $dest
    if (-not [string]::IsNullOrWhiteSpace($destParent) -and -not (Test-Path -LiteralPath $destParent)) {
        Write-Info "Creating parent directory: $destParent"
        Invoke-IfNotDryRun { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
    }

    if ($srcIsDir) { New-DirectoryLink -path $dest -target $srcPath }
    else { New-FileLink -path $dest -target $srcPath }
}

# -----------------------
# Link Map (paths from repo root)
# -----------------------
$linkMap = @{
    ($PROFILE.CurrentUserAllHosts) = (RepoPath 'scripts\Profile.ps1')
    (Join-Path $HOME '.gitconfig') = (RepoPath 'git\config')
    (Join-Path $HOME '.ideavimrc') = (Join-Path $HOME 'dotfiles\idea\ideavimrc')
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json') = (RepoPath 'terminal\settings.json')
    (Join-Path $env:LOCALAPPDATA 'direnv') = (Join-Path $HOME 'dotfiles\config\direnv')
    (Join-Path $env:LOCALAPPDATA 'fastfetch') = (RepoPath 'fastfetch')
    (Join-Path $env:LOCALAPPDATA 'lazygit') = (Join-Path $HOME 'dotfiles\config\lazygit')
    (Join-Path $env:LOCALAPPDATA 'nvim') = (Join-Path $HOME 'dotfiles\config\lazyvim')
    (Join-Path $env:APPDATA '.spacemacs.d\config') = (Join-Path $HOME 'dotfiles\spacemacs\config')
    (Join-Path $env:APPDATA '.spacemacs.d\init.el') = (Join-Path $HOME 'dotfiles\spacemacs\spacemacs_full')
    (Join-Path $env:APPDATA 'gitui') = (Join-Path $HOME 'dotfiles\config\gitui')
    (Join-Path $env:APPDATA 'helix') = (Join-Path $HOME 'dotfiles\config\helix')
    (Join-Path $env:APPDATA 'yazi\config') = (Join-Path $HOME 'dotfiles\config\yazi')
}

function Create-Links {
    if ($SkipLinks) { Write-Info 'Skipping link creation.'; return }
    Write-Info 'Creating configuration links...'
    foreach ($kvp in $linkMap.GetEnumerator()) {
        Write-Info "Link: $($kvp.Key) -> $($kvp.Value)"
        Ensure-Link -dest $kvp.Key -src $kvp.Value
    }
    Write-Info 'Link creation step complete.'
}

# -----------------------
# Execution
# -----------------------
try {
    if (-not (Test-IsAdmin)) {
        Write-Warn 'Not running as Administrator. Some installs or links may require elevation.'
    }
    Install-Packages
    Install-PowerShellModules
    Create-Links
    Write-Info 'Script completed successfully.'
} catch {
    Write-Err $_
    exit 1
}

