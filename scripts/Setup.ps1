<#
=================================================================
 Windows Setup Script (refactored)
 - Installs common tools via winget and Scoop
 - Creates idempotent links to config files and folders
 - Safer fallbacks for link creation (junction/hardlink/copy)
 Run as a regular user; it prompts for UAC approval only for the one
 step that needs it (Developer Mode, long paths, the agent power
 plan). Decline the prompt to skip just that step.
 Usage examples:
   pwsh -ExecutionPolicy Bypass -File .\scripts\Setup.ps1
   pwsh -File .\scripts\Setup.ps1 -SkipPackages
   pwsh -File .\scripts\Setup.ps1 -DryRun
   pwsh -File .\scripts\Setup.ps1 -LogLevel Debug
   pwsh -File .\scripts\Setup.ps1 -DesktopMode Native
=================================================================
#>

param(
    [switch]$SkipPackages,
    [switch]$SkipLinks,
    [switch]$SkipFonts,
    [switch]$SkipPowerToys,
    [switch]$SkipEmacs,
    [switch]$DryRun,
    [switch]$Force,
    [ValidateSet('Native', 'Komorebi')]
    [string]$DesktopMode = 'Native',
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:TOOLS = Join-Path $HOME 'local/tools'

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [int[]]$SuccessExitCodes = @(0)
    )

    if ($DryRun) { return $true }

    $nativeOutput = @(& $Action 2>&1)
    if ($LASTEXITCODE -notin $SuccessExitCodes) {
        $nativeOutput | Out-Host
        Write-Warn "$Description failed with exit code $LASTEXITCODE."
        return $false
    }

    if (Test-LogLevel 'Debug') { $nativeOutput | Out-Host }

    return $true
}

function Install-WingetPackage {
    param([Parameter(Mandatory)][string]$Id)

    winget list -e --id $Id --accept-source-agreements *>$null
    if ($LASTEXITCODE -eq 0) {
        Write-DebugInfo "winget package is installed; checking for updates: $Id"
        return Invoke-NativeCommand -Description "winget package update $Id" -SuccessExitCodes @(0, -1978335189) -Action {
            winget upgrade -e --id $Id --silent --accept-source-agreements --accept-package-agreements
        }
    }

    Write-Info "winget install -e --id $Id"
    return Invoke-NativeCommand -Description "winget package $Id" -Action {
        winget install -e --id $Id --silent --accept-source-agreements --accept-package-agreements
    }
}

function Install-ScoopPackage {
    param([Parameter(Mandatory)][string]$Name)

    scoop prefix $Name *>$null
    if ($LASTEXITCODE -eq 0) {
        Write-DebugInfo "scoop package is installed; checking for updates: $Name"
        return Invoke-NativeCommand -Description "Scoop package update $Name" -Action { scoop update $Name }
    }

    Write-Info "scoop install $Name"
    return Invoke-NativeCommand -Description "Scoop package $Name" -Action { scoop install $Name }
}

function Install-BunPackage {
    param([Parameter(Mandatory)][string]$Name)

    Write-Info "bun add --global $Name"
    return Invoke-NativeCommand -Description "Bun package $Name" -Action { bun add --global $Name }
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
    }
    else {
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
        }
        else {
            Set-ObjectProperty -Object $Destination -Name $sourceProperty.Name -Value $sourceProperty.Value
        }
    }
}

function Ensure-HomeEnv {
    $currentUserHome = [Environment]::GetEnvironmentVariable('HOME', 'User')
    if ($currentUserHome -ne $HOME) {
        Write-Info "Setting user environment variable HOME=$HOME"
        Invoke-IfNotDryRun { [Environment]::SetEnvironmentVariable('HOME', $HOME, 'User') }
    }
    else {
        Write-Info 'HOME already set at user scope.'
    }
}

function Ensure-UserBinOnPath {
    $binDirectory = Join-Path $HOME 'bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = @($userPath -split ';' | Where-Object { $_ })
    if ($pathEntries -notcontains $binDirectory) {
        Write-Info "Adding $binDirectory to the user PATH"
        Invoke-IfNotDryRun { [Environment]::SetEnvironmentVariable('Path', (($pathEntries + $binDirectory) -join ';'), 'User') }
    }
}

function Invoke-ElevatedScript {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [hashtable]$Arguments = @{}
    )

    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
    foreach ($entry in $Arguments.GetEnumerator()) {
        if ($entry.Value -is [switch] -or $entry.Value -is [bool]) {
            if ($entry.Value) { $argumentList += "-$($entry.Key)" }
        }
        else {
            $argumentList += "-$($entry.Key)", "$($entry.Value)"
        }
    }

    $shell = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $shell) { $shell = Get-Command powershell -CommandType Application -ErrorAction Stop | Select-Object -First 1 }

    try {
        $process = Start-Process -FilePath $shell.Source -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
        return $process.ExitCode -eq 0
    }
    catch {
        return $false
    }
}

function Configure-Registry {
    $registryScript = Join-Path $PSScriptRoot 'Configure-Registry.ps1'
    if (-not (Test-Path -LiteralPath $registryScript)) {
        throw "Registry configuration script not found: $registryScript"
    }

    $registryArgs = @{ LogLevel = $LogLevel }
    if ($DryRun) { $registryArgs['DryRun'] = $true }

    & $registryScript @registryArgs
    if (-not $?) { throw 'Registry configuration failed.' }

    if (-not (Test-IsAdmin)) {
        Write-Info 'Requesting administrator approval to enable Developer Mode, long paths, persistent ssh-agent, and the agent power plan...'
        if (-not (Invoke-ElevatedScript -ScriptPath $registryScript -Arguments $registryArgs)) {
            Write-Warn 'Admin-only registry, ssh-agent, and power-plan settings were skipped (elevation declined or failed). Symlink creation may require Developer Mode to be enabled manually.'
        }
    }
}

function Unlock-SshKey {
    $unlockScript = Join-Path $PSScriptRoot 'Unlock-SshKey.ps1'
    if (-not (Test-Path -LiteralPath $unlockScript)) {
        throw "SSH key unlock script not found: $unlockScript"
    }

    $unlockArgs = @{ LogLevel = $LogLevel }
    if ($DryRun) { $unlockArgs['DryRun'] = $true }

    & $unlockScript @unlockArgs
    if (-not $?) { throw 'SSH key unlock failed.' }
}

# -----------------------
# Package Installation
# -----------------------
function Install-Packages {
    if ($SkipPackages) { Write-Info 'Skipping package installation.'; return }

    $packageFailures = [System.Collections.Generic.List[string]]::new()

    # Winget apps (install per-ID for clearer output and retries)
    $wingetApps = @(
        'Dropbox.Dropbox', 'FSFhu.Hunspell', 'HTTPie.HTTPie', 'IJHack.QtPass', 'LGUG2Z.masir', 'Microsoft.PowerShell', 'Microsoft.PowerToys',
        'Microsoft.VisualStudioCode', 'Microsoft.WindowsTerminal',
        'WinFsp.WinFsp'
    )

    if (Test-Command 'winget') {
        Write-Info 'Installing applications via winget...'
        foreach ($id in $wingetApps) {
            if (-not (Install-WingetPackage -Id $id)) {
                $packageFailures.Add("winget:$id")
            }
        }
    }
    else {
        Write-Warn 'winget not found; skipping winget apps.'
    }

    # Scoop is the primary package manager for portable applications. Run
    # scripts\Bootstrap.ps1 first on a machine that doesn't have it yet.

    $scoopBuckets = @('extras')
    $scoopAppsMain = @(
        '7zip', 'ag', 'aspell', 'bat', 'bitwarden-cli', 'bottom', 'broot', 'btop', 'bun', 'busybox', 'cmake', 'curl',
        'delta', 'direnv', 'dust', 'eza', 'far', 'fastfetch', 'fd', 'file', 'ffmpeg', 'fzf', 'gdu', 'gh', 'git', 'gitui',
        'glow', 'gnupg', 'go', 'gping', 'helix', 'jq', 'lazygit', 'lsd', 'lua', 'mosh-client', 'msys2',
        'navi', 'neovim', 'nodejs-lts', 'ouch', 'pandoc', 'prek', 'procs', 'pwsh', 'python', 'ripgrep', 'rustup',
        'rclone', 'sd', 'sed', 'shellcheck', 'shfmt', 'sqlite', 'starship', 'sysinternals', 'tealdeer', 'tectonic', 'texlab',
        'tree-sitter', 'uv', 'vale', 'vim', 'watchexec', 'wget', 'xh', 'yazi', 'yt-dlp', 'zellij', 'zoxide'
    )
    $scoopAppsExtras = @(
        'activitywatch', 'antigravity-ide', 'autohotkey', 'bitwarden', 'extras/chatgpt', 'extras/claude', 'emacs', 'gitu', 'googlechrome', 'gpg4win', 'handbrake', 'herdr', 'kanata',
        'komokana', 'komorebi', 'mupdf', 'notepadplusplus', 'television', 'totalcommander', 'vlc', 'wezterm',
        'quarto', 'winrar', 'yasb', 'zed'
    )
    $bunApps = @(
        'antigravity-cli', 'copilot-cli', 'opencode-ai', 'oh-my-pi', 'pi-coding-agent',
        '@anthropic-ai/claude-code@latest', '@google/gemini-cli@latest', '@marp-team/marp-cli',
        '@openai/codex@latest', 'bibtex-tidy',
        'dockerfile-language-server-nodejs', 'js-beautify', 'prettier',
        'typescript', 'typescript-formatter', 'typescript-language-server', 'vim-language-server',
        'vscode-json-languageserver', 'yaml-language-server'
    )

    if (Test-Command 'scoop') {
        Write-Info 'Ensuring scoop buckets and apps are installed...'
        foreach ($b in $scoopBuckets) {
            $bucketExists = (scoop bucket list | Out-String) -match "(?m)^$([regex]::Escape($b))\s"
            $scoopRoot = if ([string]::IsNullOrWhiteSpace($env:SCOOP)) { Join-Path $HOME 'scoop' } else { $env:SCOOP }
            $bucketHealthy = (Test-Path -LiteralPath (Join-Path $scoopRoot "buckets\$b\.git\config")) -and
            (Test-Path -LiteralPath (Join-Path $scoopRoot "buckets\$b\bucket"))
            if ($bucketExists -and -not $bucketHealthy) {
                Write-Warn "Scoop bucket $b is incomplete; recreating it."
                if (-not (Invoke-NativeCommand -Description "Scoop bucket removal $b" -Action { scoop bucket rm $b })) {
                    $packageFailures.Add("scoop bucket:$b")
                    continue
                }
                $bucketExists = $false
            }
            if (-not $bucketExists) {
                Write-Info "scoop bucket add $b"
                if (-not (Invoke-NativeCommand -Description "Scoop bucket $b" -Action { scoop bucket add $b })) {
                    $packageFailures.Add("scoop bucket:$b")
                }
            }
        }
        if ($scoopAppsMain.Count -gt 0) {
            foreach ($app in $scoopAppsMain) {
                if (-not (Install-ScoopPackage -Name $app)) {
                    $packageFailures.Add("scoop:$app")
                }
            }
        }
        if ($scoopAppsExtras.Count -gt 0) {
            foreach ($app in $scoopAppsExtras) {
                if (-not (Install-ScoopPackage -Name $app)) {
                    $packageFailures.Add("scoop:$app")
                }
            }
        }

        if (Test-Command 'bun') {
            foreach ($app in $bunApps) {
                if (-not (Install-BunPackage -Name $app)) {
                    $packageFailures.Add("bun:$app")
                }
            }
        }
        else {
            Write-Warn 'bun not found after Scoop installation; skipping Bun packages.'
        }
    }
    else {
        Write-Warn 'scoop not found; run scripts\Bootstrap.ps1 first. Skipping scoop apps.'
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
        }
        else {
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
    }
    catch {
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

function Install-Dotfiles {
    [void](Ensure-GitCheckout -Name 'dotfiles' -Repository 'https://github.com/aam-at/dotfiles.git' -Destination (Join-Path $HOME 'dotfiles'))
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

        $shell = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $shell) { $shell = Get-Command powershell -CommandType Application -ErrorAction Stop | Select-Object -First 1 }

        Write-Info 'Installing Doom packages and generating its initial state...'
        if (-not (Invoke-NativeCommand -Description 'Doom installation' -Action { & $shell.Source -NoProfile -ExecutionPolicy Bypass -File $doomProfileScript install --force })) {
            throw 'Doom installation failed.'
        }

        New-Item -ItemType Directory -Path (Split-Path -Parent $doomMarker) -Force | Out-Null
        Set-Content -LiteralPath $doomMarker -Value 'Installed by windots Setup.ps1' -Encoding utf8 -NoNewline
    }
    else {
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
    if ($DryRun) { return }

    & powershell @fontArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Font installation failed for $Name."
    }
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
    }
    catch {
        Write-Warn 'PSGallery repository not found or PowerShellGet not loaded.'
    }

    foreach ($psModule in $psModules) {
        if (-not (Get-Module -ListAvailable -Name $psModule)) {
            Write-Info "Installing PS module: $psModule"
            Invoke-IfNotDryRun { Install-Module -Name $psModule -Force -AcceptLicense -Scope CurrentUser -Repository PSGallery }
        }
        else {
            Write-Info "PS module already available: $psModule"
        }
    }
}

# -----------------------
# Fonts Map
# -----------------------
$fontsMap = @{
    "adobe-fonts"     = "https://github.com/adobe-fonts/source-code-pro.git"
    "all-icons-fonts" = "https://github.com/domtronn/all-the-icons.el.git"
    "iawriter-fonts"  = "https://github.com/iaolo/iA-Fonts.git"
    "icons-fonts"     = "https://github.com/sebastiencs/icons-in-terminal.git"
    "jetbrains-fonts" = "https://github.com/JetBrains/JetBrainsMono.git"
    "nerd-fonts"      = "https://github.com/ryanoasis/nerd-fonts.git"
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

function Install-Links {
    $linkScript = Join-Path $PSScriptRoot 'Install-Links.ps1'
    if (-not (Test-Path -LiteralPath $linkScript)) {
        throw "Link installer not found: $linkScript"
    }

    # Hashtable splat, not array splat: array elements bind positionally and
    # silently drop these switches instead of raising a binding error.
    $linkArgs = @{ LogLevel = $LogLevel; DesktopMode = $DesktopMode }
    if ($SkipLinks) { $linkArgs['SkipConfigLinks'] = $true }
    if ($DryRun) { $linkArgs['DryRun'] = $true }
    if ($Force) { $linkArgs['Force'] = $true }

    & $linkScript @linkArgs
    if (-not $?) { throw 'Link installation failed.' }
}

# -----------------------
# Execution
# -----------------------
try {
    Configure-Registry
    Unlock-SshKey
    Ensure-HomeEnv
    Install-Packages
    Ensure-UserBinOnPath
    Install-Dotfiles
    Install-PowerShellModules
    Configure-PowerToys
    Install-Links
    # Install-EmacsDistributions
    Download-And-Install-Fonts
    Write-Info 'Script completed successfully.'
}
catch {
    Write-Err $_
    exit 1
}
finally {
    if (($script:Warnings.Count -gt 0) -and (Test-LogLevel 'Warn')) {
        Write-Host ''
        Write-Host "[SUMMARY] Completed with $($script:Warnings.Count) warning(s):" -ForegroundColor Yellow
        foreach ($w in $script:Warnings) { Write-Host "  - $w" -ForegroundColor Yellow }
    }
}
