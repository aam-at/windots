<#
=================================================================
 Windows Setup Script (refactored)
 - Installs common tools via winget and Scoop
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
    [switch]$SkipPowerToys,
    [switch]$SkipEmacs,
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

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    if ($DryRun) { return $true }

    & $Action
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "$Description failed with exit code $LASTEXITCODE."
        return $false
    }

    return $true
}

# Resolve repo root regardless of invocation CWD
$RepoRoot = Split-Path -Parent $PSScriptRoot
function RepoPath([string]$Relative) { return (Join-Path $RepoRoot $Relative) }

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        $Value
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $property.Value = $Value
    }
}

function Merge-ObjectProperties {
    param(
        [Parameter(Mandatory)]
        [psobject]$Destination,

        [Parameter(Mandatory)]
        [psobject]$Source
    )

    foreach ($sourceProperty in $Source.PSObject.Properties) {
        $destinationProperty = $Destination.PSObject.Properties[$sourceProperty.Name]
        if (($null -ne $destinationProperty) -and
            ($destinationProperty.Value -is [pscustomobject]) -and
            ($sourceProperty.Value -is [pscustomobject])) {
            Merge-ObjectProperties -Destination $destinationProperty.Value -Source $sourceProperty.Value
        } else {
            Set-ObjectProperty -Object $Destination -Name $sourceProperty.Name -Value $sourceProperty.Value
        }
    }
}

# -----------------------
# System Settings
# -----------------------
function Enable-LongPaths {
    if (-not (Test-IsAdmin)) {
        Write-Warn 'Skipping Win32 long paths support; it requires an elevated session.'
        return
    }

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

    $packageFailures = [System.Collections.Generic.List[string]]::new()

    # Winget apps (install per-ID for clearer output and retries)
    $wingetApps = @(
        'Dropbox.Dropbox', 'Hunspell', 'LGUG2Z.masir', 'Microsoft.PowerShell', 'Microsoft.PowerToys',
        'Microsoft.Sysinternals.Suite', 'Microsoft.VisualStudioCode', 'Microsoft.WindowsTerminal', 'qtpass',
        'WinFsp.WinFsp'
    )

    if (Test-Command 'winget') {
        if (Test-IsAdmin) {
            Write-Info 'Installing applications via winget...'
            foreach ($id in $wingetApps) {
                Write-Info "winget install -e --scope machine --id $id"
                if (-not (Invoke-NativeCommand -Description "winget package $id" -Action { winget install -e --scope machine --id $id --silent --accept-source-agreements --accept-package-agreements | Out-Null })) {
                    $packageFailures.Add("winget:$id")
                }
            }
        } else {
            Write-Warn 'Skipping winget apps because --scope machine requires an elevated session.'
        }
    } else {
        Write-Warn 'winget not found; skipping winget apps.'
    }

    if (-not (Test-Command 'scoop')) {
        Write-Info 'Installing Scoop for the current user...'
        Invoke-IfNotDryRun {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
            Invoke-RestMethod -Uri 'https://get.scoop.sh' | Invoke-Expression
        }
    }

    # Scoop is the primary package manager for portable applications.
    $scoopBuckets = @('extras')
    $scoopAppsMain = @(
        '7zip', 'ag', 'aspell', 'bat', 'bitwarden-cli', 'bottom', 'broot', 'btop', 'bun', 'claude-code', 'cmake', 'codex', 'curl',
        'delta', 'direnv', 'dust', 'eza', 'far', 'fastfetch', 'fd', 'ffmpeg', 'fzf', 'gdu', 'gh', 'git', 'gitui',
        'glow', 'gnupg', 'go', 'gping', 'gzip', 'helix', 'htop', 'httpie', 'jq', 'lsd', 'lua', 'mosh', 'msys2',
        'navi', 'ncdu', 'neovim', 'nodejs-lts', 'ouch', 'pandoc', 'procs', 'pwsh', 'python', 'ripgrep', 'rustup',
        'sd', 'sed', 'shellcheck', 'shfmt', 'sqlite', 'starship', 'tealdeer', 'tectonic', 'texlab', 'tig',
        'tar', 'tree-sitter', 'uv', 'vale', 'vim', 'watchexec', 'wget', 'xh', 'yazi', 'yt-dlp', 'zellij', 'zoxide'
    )
    $scoopAppsExtras = @(
        'activitywatch', 'autohotkey', 'bitwarden', 'emacs', 'googlechrome', 'gitu', 'gpg4win', 'handbrake', 'kanata',
        'komokana', 'komorebi', 'mupdf', 'notepadplusplus', 'television', 'totalcommander', 'vlc', 'wezterm',
        'winrar', 'yasb', 'zed'
    )

    if (Test-Command 'scoop') {
        Write-Info 'Ensuring scoop buckets and apps are installed...'
        foreach ($b in $scoopBuckets) {
            $bucketExists = (scoop bucket list | Out-String) -match "(?m)^$([regex]::Escape($b))\s"
            if (-not $bucketExists) {
                Write-Info "scoop bucket add $b"
                if (-not (Invoke-NativeCommand -Description "Scoop bucket $b" -Action { scoop bucket add $b | Out-Null })) {
                    $packageFailures.Add("scoop bucket:$b")
                }
            }
        }
        if ($scoopAppsMain.Count -gt 0) {
            foreach ($app in $scoopAppsMain) {
                Write-Info "scoop install $app"
                if (-not (Invoke-NativeCommand -Description "Scoop package $app" -Action { scoop install $app | Out-Null })) {
                    $packageFailures.Add("scoop:$app")
                }
            }
        }
        if ($scoopAppsExtras.Count -gt 0) {
            foreach ($app in $scoopAppsExtras) {
                Write-Info "scoop install $app"
                if (-not (Invoke-NativeCommand -Description "Scoop package $app" -Action { scoop install $app | Out-Null })) {
                    $packageFailures.Add("scoop:$app")
                }
            }
        }
    } else {
        Write-Warn 'scoop not found; skipping scoop apps.'
    }

    if ($packageFailures.Count -gt 0) {
        throw "Package installation failed: $($packageFailures -join ', ')"
    }

    Write-Info 'Package installation step complete.'
}

# -----------------------
# PowerToys Productivity Settings
# -----------------------
function Configure-PowerToys {
    if ($SkipPowerToys) { Write-Info 'Skipping PowerToys configuration.'; return }

    $powerToysExe = Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe'
    if (-not (Test-Path -LiteralPath $powerToysExe)) {
        Write-Warn 'PowerToys is not installed; skipping PowerToys configuration.'
        return
    }

    $templatePath = RepoPath 'powertoys\settings.json'
    $settingsDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys'
    $settingsPath = Join-Path $settingsDirectory 'settings.json'
    if (-not (Test-Path -LiteralPath $templatePath)) {
        Write-Warn "PowerToys settings template not found: $templatePath"
        return
    }

    try {
        $template = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json
        if (Test-Path -LiteralPath $settingsPath) {
            $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
        } else {
            $settings = [pscustomobject]@{}
        }

        Merge-ObjectProperties -Destination $settings -Source $template
        $settingsJson = $settings | ConvertTo-Json -Depth 10

        if (-not (Test-Path -LiteralPath $settingsDirectory)) {
            Write-Info "Creating PowerToys settings directory: $settingsDirectory"
            Invoke-IfNotDryRun { New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null }
        }

        if ((Test-Path -LiteralPath $settingsPath) -and (-not (Test-Path -LiteralPath "$settingsPath.windots-backup"))) {
            Write-Info "Backing up PowerToys settings: $settingsPath.windots-backup"
            Invoke-IfNotDryRun { Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.windots-backup" -ErrorAction Stop }
        }

        Write-Info 'Applying PowerToys productivity settings...'
        Invoke-IfNotDryRun { Set-Content -LiteralPath $settingsPath -Value $settingsJson -Encoding utf8 -NoNewline }
        Write-Info 'PowerToys settings saved. Restart PowerToys to apply them to the current session.'
    } catch {
        Write-Warn "Failed to configure PowerToys: $_"
    }
}

# -----------------------
# Emacs Distributions
# -----------------------
function Ensure-GitCheckout {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        if (Test-Path -LiteralPath (Join-Path $Destination '.git')) {
            Write-Info "$Name framework already present: $Destination"
            return $false
        }

        Write-Warn "$Name destination exists but is not a Git checkout; preserving it: $Destination"
        return $false
    }

    if (-not (Test-Command 'git')) {
        throw "Git is required to install the $Name framework."
    }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        Write-Info "Creating Emacs framework directory: $parent"
        Invoke-IfNotDryRun { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }

    Write-Info "Cloning $Name framework..."
    if (-not (Invoke-NativeCommand -Description "$Name framework" -Action { git clone --depth=1 $Repository $Destination | Out-Null })) {
        throw "Unable to clone the $Name framework."
    }

    return $true
}

function Install-EmacsDistributions {
    if ($SkipEmacs) { Write-Info 'Skipping Emacs distribution setup.'; return }

    $dotfilesEmacs = Join-Path $HOME 'dotfiles\emacs'
    if (-not (Test-Path -LiteralPath $dotfilesEmacs)) {
        Write-Warn "Shared Emacs profiles not found at $dotfilesEmacs; skipping Emacs distribution setup."
        return
    }

    $emacsConfigRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) { Join-Path $HOME '.config\emacs' } else { Join-Path $env:XDG_CONFIG_HOME 'emacs' }
    $emacsDataRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_DATA_HOME)) { Join-Path $HOME '.local\share\emacs' } else { Join-Path $env:XDG_DATA_HOME 'emacs' }
    $emacsStateRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_STATE_HOME)) { Join-Path $HOME '.local\state\emacs' } else { Join-Path $env:XDG_STATE_HOME 'emacs' }
    $doomFramework = Join-Path $emacsDataRoot 'doom'
    $spacemacsFramework = Join-Path $emacsDataRoot 'spacemacs'

    [void](Ensure-GitCheckout -Name 'Doom' -Repository 'https://github.com/doomemacs/doomemacs.git' -Destination $doomFramework)
    [void](Ensure-GitCheckout -Name 'Spacemacs' -Repository 'https://github.com/syl20bnr/spacemacs.git' -Destination $spacemacsFramework)

    if ($DryRun) {
        Write-Info 'Doom installation would run after the frameworks and profiles are available.'
        return
    }

    if (-not (Test-Path -LiteralPath (Join-Path $emacsConfigRoot 'doom\init.el'))) {
        Write-Warn "Doom profile is not linked at $emacsConfigRoot\doom; skipping Doom installation."
        return
    }

    $doomMarker = Join-Path $emacsStateRoot 'doom\.windots-installed'
    if (-not (Test-Path -LiteralPath $doomMarker)) {
        $doomProfileScript = Join-Path $PSScriptRoot 'doom-profile.ps1'
        if (-not (Test-Path -LiteralPath $doomProfileScript)) {
            throw "Doom profile launcher not found: $doomProfileScript"
        }

        $shell = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue
        if ($null -eq $shell) { $shell = Get-Command powershell -CommandType Application -ErrorAction Stop }

        Write-Info 'Installing Doom packages and generating its initial state...'
        if (-not (Invoke-NativeCommand -Description 'Doom installation' -Action { & $shell.Source -NoProfile -ExecutionPolicy Bypass -File $doomProfileScript install })) {
            throw 'Doom installation failed.'
        }

        New-Item -ItemType Directory -Path (Split-Path -Parent $doomMarker) -Force | Out-Null
        Set-Content -LiteralPath $doomMarker -Value 'Installed by windots Setup.ps1' -Encoding utf8 -NoNewline
    } else {
        Write-Info 'Doom initial installation already completed.'
    }

    Write-Info 'Spacemacs will install its profile packages when you first open a Spacemacs profile.'
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

    $fontsRoot = $env:TOOLS
    $dest = Join-Path $fontsRoot $Name
    if (-not (Test-Path -LiteralPath $fontsRoot)) {
        Write-Info "Creating fonts directory: $fontsRoot"
        Invoke-IfNotDryRun { New-Item -ItemType Directory -Path $fontsRoot -Force | Out-Null }
    }

    if (-not (Test-Path $dest)) {
        Write-Host "Cloning $Name..."
        if (-not (Invoke-NativeCommand -Description "font repository $Name" -Action { git clone --depth=1 "$RepoUrl" "$dest" | Out-Null })) {
            throw "Unable to clone font repository: $Name"
        }
    }

    Write-Host "Installing fonts from $dest..."
    $fontInstaller = Join-Path $PSScriptRoot 'install_fonts.ps1'
    $fontArgs = @('-ExecutionPolicy', 'Bypass', '-File', $fontInstaller, '-fontFolder', $dest)
    if (-not (Test-IsAdmin)) { $fontArgs += '-CurrentUser' }
    Invoke-IfNotDryRun { & powershell @fontArgs | Out-Null }
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

        $cmdLine = '"{0}" start --ahk --masir' -f $exePath
        Write-Info "Configuring startup: $name -> $cmdLine"
        Invoke-IfNotDryRun { New-ItemProperty -Path $runKey -Name $name -Value $cmdLine -PropertyType String -Force | Out-Null }
    } catch {
        Write-Warn 'Failed to configure Komorebi startup entry.'
    }
}

# -----------------------
# YASB Startup
# -----------------------
function Ensure-YasbStartup {
    try {
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $name = 'YASB'

        $exePath = $null
        foreach ($candidate in @('yasb', 'yasb.exe')) {
            $c = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($c -and $c.Path) { $exePath = $c.Path; break }
        }

        if (-not $exePath) {
            Write-Warn 'yasb executable not found on PATH; skipping startup entry.'
            return
        }

        $cmdLine = '"{0}"' -f $exePath
        Write-Info "Configuring startup: $name -> $cmdLine"
        Invoke-IfNotDryRun { New-ItemProperty -Path $runKey -Name $name -Value $cmdLine -PropertyType String -Force | Out-Null }
    } catch {
        Write-Warn 'Failed to configure YASB startup entry.'
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

        $cmdLine = if (Test-Path -LiteralPath $cfg) { '"{0}" -c "{1}"' -f $exePath, $cfg } else { '"{0}"' -f $exePath }

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
    if (-not (Test-Path -LiteralPath $path)) { return $true }

    $item = Get-Item -LiteralPath $path -Force
    $isLink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if (-not $isLink -and -not $Force) {
        Write-Warn "Existing path is not a link; preserving it. Re-run with -Force to replace: $path"
        return $false
    }

    Write-Info "Removing existing path: $path"
    Invoke-IfNotDryRun {
        if ($isLink) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        else { Remove-Item -LiteralPath $path -Force -Recurse -ErrorAction Stop }
    }
    return $true
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
        if (-not (Remove-PathSafe $dest)) { return }
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
    (Join-Path $env:LOCALAPPDATA 'fastfetch') = (Join-Path $HOME 'dotfiles\config\fastfetch')
    (Join-Path $env:LOCALAPPDATA 'lazygit') = (Join-Path $HOME 'dotfiles\config\lazygit')
    (Join-Path $HOME '.config\starship.toml') = (Join-Path $HOME 'dotfiles\config\starship.toml')
    (Join-Path $HOME '.config\theme') = (Join-Path $HOME 'dotfiles\themes\gruvbox-dark')
    (Join-Path $HOME '.claude\settings.json') = (Join-Path $HOME 'dotfiles\config\agents\claude\settings.json')
    (Join-Path $HOME '.codex\config.toml') = (Join-Path $HOME 'dotfiles\config\agents\codex\config.toml')
    (Join-Path $env:LOCALAPPDATA 'nvim') = (Join-Path $HOME 'dotfiles\config\lazyvim')
    (Join-Path $env:LOCALAPPDATA 'television\config\config.toml') = (Join-Path $HOME 'dotfiles\config\television\config.toml')
    (Join-Path $env:APPDATA 'gitu') = (Join-Path $HOME 'dotfiles\config\gitu')
    (Join-Path $env:APPDATA 'gitui') = (Join-Path $HOME 'dotfiles\config\gitui')
    (Join-Path $env:APPDATA 'helix') = (Join-Path $HOME 'dotfiles\config\helix')
    (Join-Path $env:APPDATA 'yazi\config') = (Join-Path $HOME 'dotfiles\config\yazi')
    (Join-Path $env:APPDATA 'Zed') = (Join-Path $HOME 'dotfiles\config\zed')
    (Join-Path $HOME '.config\emacs\doom') = (Join-Path $HOME 'dotfiles\emacs\doom')
    (Join-Path $HOME '.config\emacs\config') = (Join-Path $HOME 'dotfiles\emacs\config')
    (Join-Path $HOME '.config\emacs\funcs') = (Join-Path $HOME 'dotfiles\emacs\funcs')
    (Join-Path $HOME '.config\emacs\spacemacs') = (Join-Path $HOME 'dotfiles\emacs\spacemacs')
    (Join-Path $HOME '.config\emacs\spacemacs-full\config') = (Join-Path $HOME 'dotfiles\emacs\config')
    (Join-Path $HOME '.config\emacs\spacemacs-full\funcs') = (Join-Path $HOME 'dotfiles\emacs\funcs')
    (Join-Path $HOME '.config\emacs\spacemacs-full\layers') = (Join-Path $HOME 'dotfiles\emacs\spacemacs')
    (Join-Path $HOME '.config\emacs\spacemacs-full\init.el') = (Join-Path $HOME 'dotfiles\emacs\spacemacs\spacemacs_full')
    (Join-Path $HOME '.config\emacs\spacemacs-basic\init.el') = (Join-Path $HOME 'dotfiles\emacs\spacemacs\spacemacs_basic')
    (Join-Path $HOME '.config\emacs\spacemacs-writing\config') = (Join-Path $HOME 'dotfiles\emacs\config')
    (Join-Path $HOME '.config\emacs\spacemacs-writing\funcs') = (Join-Path $HOME 'dotfiles\emacs\funcs')
    (Join-Path $HOME '.config\emacs\spacemacs-writing\layers') = (Join-Path $HOME 'dotfiles\emacs\spacemacs')
    (Join-Path $HOME '.config\emacs\spacemacs-writing\init.el') = (Join-Path $HOME 'dotfiles\emacs\spacemacs\spacemacs_writing')
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
    Configure-PowerToys
    Create-Links
    Install-EmacsDistributions
    Ensure-KomorebiStartupPath
    Ensure-YasbStartup
    Ensure-KanataStartup
    Download-And-Install-Fonts
    Write-Info 'Script completed successfully.'
} catch {
    Write-Err $_
    exit 1
}
