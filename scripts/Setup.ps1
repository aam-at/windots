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
    [switch]$SkipFonts,
    [switch]$DryRun,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:TOOLS = Join-Path $HOME 'local/tools'

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
# System Settings
# -----------------------
function Enable-LongPaths {
    try {
        Write-Info 'Enabling Win32 long paths support...'
        Invoke-IfNotDryRun { New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -PropertyType DWord -Force | Out-Null }
    } catch {
        Write-Warn 'Failed to enable long paths; try running as Administrator.'
    }
}

function Ensure-HomeEnv {
    try {
        $desired = if (-not [string]::IsNullOrWhiteSpace($HOME)) { $HOME } else { $env:USERPROFILE }
        if ([string]::IsNullOrWhiteSpace($desired)) { Write-Warn 'Unable to determine a value for HOME.'; return }

        $currentUserHome = [Environment]::GetEnvironmentVariable('HOME', 'User')
        if ($currentUserHome -ne $desired) {
            Write-Info "Setting user environment variable HOME=$desired"
            Invoke-IfNotDryRun { [Environment]::SetEnvironmentVariable('HOME', $desired, 'User') }
        } else {
            Write-Info 'HOME already set at user scope.'
        }

        # Ensure current process sees it too
        $env:HOME = $desired
    } catch {
        Write-Warn 'Failed to set HOME environment variable.'
    }
}

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
        'qtpass', 'vim.vim', 'wez.wezterm', 'winfsp', 'LGUG2Z.masir'
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
    $scoopAppsMain   = @('7zip', 'ag', 'aspell', 'bat', 'curl', 'delta', 'direnv', 'fastfetch', 'fd', 'ffmpeg', 'fzf', 'gitui', 'glow', 'gzip', 'lua', 'ripgrep', 'sed', 'sqlite', 'starship', 'tectonic', 'texlab', 'wget', 'yazi', 'yt-dlp')
    $scoopAppsExtras   = @('activitywatch', 'autohotkey', 'gitu', 'kanata', 'komokana', 'komorebi', 'mupdf', 'television', 'winrar', 'yasb', 'zed')

    if (Test-Command 'scoop') {
        Write-Info 'Ensuring scoop buckets and apps are installed...'
        foreach ($b in $scoopBuckets) {
            Write-Info "scoop bucket add $b"
            Invoke-IfNotDryRun { scoop bucket add $b } | Out-Null
        }
        if ($scoopAppsMain.Count -gt 0) {
            Write-Info ("scoop install " + ($scoopAppsMain -join ' '))
            Invoke-IfNotDryRun { scoop install $scoopAppsMain } | Out-Null
        }
        if ($scoopAppsExtras.Count -gt 0) {
            Write-Info ("scoop install " + ($scoopAppsExtras -join ' '))
            Invoke-IfNotDryRun { scoop install $scoopAppsExtras } | Out-Null
        }
    } else {
        Write-Warn 'scoop not found; skipping scoop apps.'
    }

    Write-Info 'Package installation step complete.'
}

# ================================================================
# Download and install fonts
# ================================================================
function Clone-AndInstall {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$RepoUrl
    )

    $dest = Join-Path $env:TOOLS $Name
    if (-not (Test-Path $dest)) {
        Write-Host "Cloning $Name..."
        git clone --depth=1 "$RepoUrl" "$dest" | Out-Null
    }

    Write-Host "Installing fonts from $dest..."
    & powershell -ExecutionPolicy Bypass -File install_fonts.ps1 -fontFolder $dest | Out-Null
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
# Startup Apps
# -----------------------
function Ensure-KomorebiStartup {
    try {
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $name = 'Komorebic'
        $exePath = Join-Path $env:USERPROFILE 'scoop\shims\komorebic-no-console.exe'
        $cmd = '%USERPROFILE%\scoop\shims\komorebic-no-console.exe start --bar --ahk --masir'

        if (-not (Test-Path -LiteralPath $exePath)) {
            Write-Warn "komorebic shim not found at $exePath; creating startup entry anyway."
        }

        Write-Info "Configuring startup: $name"
        Invoke-IfNotDryRun { New-ItemProperty -Path $runKey -Name $name -Value $cmd -PropertyType ExpandString -Force | Out-Null }
    } catch {
        Write-Warn 'Failed to configure Komorebi startup entry.'
    }
}

function Ensure-KomorebiStartupPath {
    try {
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $name = 'Komorebic'

        $exePath = $null
        foreach ($candidate in @('komorebic-no-console','komorebic')) {
            $c = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($c -and $c.Path) { $exePath = $c.Path; break }
        }

        if (-not $exePath) {
            Write-Warn 'komorebic executable not found on PATH; skipping startup entry.'
            return
        }

        $cmdLine = '"{0}" start --bar --ahk --masir' -f $exePath
        Write-Info "Configuring startup: $name -> $cmdLine"
        Invoke-IfNotDryRun { New-ItemProperty -Path $runKey -Name $name -Value $cmdLine -PropertyType String -Force | Out-Null }
    } catch {
        Write-Warn 'Failed to configure Komorebi startup entry.'
    }
}

# -----------------------
# Kanata Startup
# -----------------------
function Ensure-KanataStartup {
    try {
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $name = 'Kanata'

        $exePath = $null
        foreach ($candidate in @('kanata_gui','kanata-gui','kanata')) {
            $c = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($c -and $c.Path) { $exePath = $c.Path; break }
        }

        if (-not $exePath) {
            Write-Warn 'kanata executable not found on PATH; skipping startup entry.'
            return
        }

        $cfg = Join-Path $RepoRoot 'kanata\config.kbd'
        if ((-not (Test-Path -LiteralPath $cfg)) -and $DebugPreference) {
            Write-Warn "kanata config not found at $cfg; proceeding without -c argument."
        }

        if ($exePath -match 'kanata_gui|kanata-gui') {
            $cmdLine = '"{0}"' -f $exePath
        } else {
            $cmdLine = if (Test-Path -LiteralPath $cfg) { '"{0}" -c "{1}"' -f $exePath, $cfg } else { '"{0}"' -f $exePath }
        }

        Write-Info "Configuring startup: $name -> $cmdLine"
        Invoke-IfNotDryRun { New-ItemProperty -Path $runKey -Name $name -Value $cmdLine -PropertyType String -Force | Out-Null }
    } catch {
        Write-Warn 'Failed to configure Kanata startup entry.'
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
    (Join-Path $HOME '.config\wezterm') = (Join-Path $HOME 'dotfiles\config\wezterm')
    (Join-Path $HOME '.config\yasb') = (RepoPath 'yasb')
    (Join-Path $HOME '.gitconfig') = (RepoPath 'git\config')
    (Join-Path $HOME '.ideavimrc') = (Join-Path $HOME 'dotfiles\idea\ideavimrc')
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json') = (RepoPath 'terminal\settings.json')
    (Join-Path $env:LOCALAPPDATA 'direnv') = (Join-Path $HOME 'dotfiles\config\direnv')
    (Join-Path $env:LOCALAPPDATA 'fastfetch') = (RepoPath 'fastfetch')
    (Join-Path $env:LOCALAPPDATA 'lazygit') = (Join-Path $HOME 'dotfiles\config\lazygit')
    (Join-Path $env:LOCALAPPDATA 'nvim') = (Join-Path $HOME 'dotfiles\config\lazyvim')
    (Join-Path $env:LOCALAPPDATA 'television\config\config.toml') = (Join-Path $HOME 'dotfiles\config\television\config.toml')
    (Join-Path $env:APPDATA 'gitu') = (Join-Path $HOME 'dotfiles\config\gitu')
    (Join-Path $env:APPDATA 'gitui') = (Join-Path $HOME 'dotfiles\config\gitui')
    (Join-Path $env:APPDATA 'helix') = (Join-Path $HOME 'dotfiles\config\helix')
    (Join-Path $env:APPDATA 'yazi\config') = (Join-Path $HOME 'dotfiles\config\yazi')
    (Join-Path $env:APPDATA 'Zed') = (Join-Path $HOME 'dotfiles\config\zed')
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
# Fonts Map
# -----------------------
$fontsMap = @{
  "adobe-fonts" = "https://github.com/adobe-fonts/source-code-pro.git"
  "all-icons-fonts" = "https://github.com/domtronn/all-the-icons.el.git"
  "iawriter-fonts" = "https://github.com/iaolo/iA-Fonts.git"
  "icons-fonts" = "https://github.com/sebastiencs/icons-in-terminal.git"
  "jetbrains-fonts" = "https://github.com/JetBrains/JetBrainsMono.git"
  "nerd-fonts" = "https://github.com/ryanoasis/nerd-fonts.git"
  "powerline-fonts" = "https://github.com/powerline/fonts.git"
}

function Download-And-Install-Fonts {
  if ($SkipFonts) { Write-Info 'Skipping fonts installation.'; return }
  Write-Info 'Downloading and installing fonts...'
    foreach ($kvp in $fontsMap.GetEnumerator()) {
      Clone-AndInstall -Name $kvp.Key -RepoUrl $kvp.Value
    }
  Write-Info 'Font installation step complete.'
}

# -----------------------
# Execution
# -----------------------
try {
    if (-not (Test-IsAdmin)) {
        Write-Warn 'Not running as Administrator. Some installs or links may require elevation.'
    }
    Enable-LongPaths
    Ensure-HomeEnv
    Install-Packages
    Install-PowerShellModules
    Create-Links
    Ensure-KomorebiStartupPath
    Ensure-KanataStartup
    Download-And-Install-Fonts
    Write-Info 'Script completed successfully.'
} catch {
    Write-Err $_
    exit 1
}
