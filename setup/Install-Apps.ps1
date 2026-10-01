<#
Installs applications via winget, Scoop, Bun and uv, plus PowerShell modules and
VirtualDesktopAccessor.dll (used by shells\native\Native-Desktop.ahk).

Usage:
  pwsh -File .\setup\Install-Apps.ps1
  pwsh -File .\setup\Install-Apps.ps1 -DryRun

Scoop is the primary package manager for portable applications. Run
setup\Bootstrap.ps1 first on a machine that doesn't have it yet.
#>

[CmdletBinding()]
param(
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

function Install-WingetPackage {
    param([Parameter(Mandatory)][string]$Id, [string[]]$Override)

    winget list -e --id $Id --accept-source-agreements *>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Verbose "winget package is installed; checking for updates: $Id"
        return Invoke-NativeCommand -Description "winget package update $Id" -SuccessExitCodes @(0, -1978335189) -Action {
            winget upgrade -e --id $Id --silent --accept-source-agreements --accept-package-agreements
        }
    }

    Write-Info "winget install -e --id $Id"
    return Invoke-NativeCommand -Description "winget package $Id" -Action {
        winget install -e --id $Id --silent --accept-source-agreements --accept-package-agreements @Override
    }
}

function Install-ScoopPackage {
    # Source is a bucket app name or a manifest path (for scoop\*.json in this repo).
    param([Parameter(Mandatory)][string]$Name, [string]$Source = $Name)

    scoop prefix $Name *>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Verbose "scoop package is installed; checking for updates: $Name"
        return Invoke-NativeCommand -Description "Scoop package update $Name" -Action { scoop update $Name }
    }

    Write-Info "scoop install $Source"
    return Invoke-NativeCommand -Description "Scoop package $Name" -Action { scoop install $Source }
}

$packageFailures = [System.Collections.Generic.List[string]]::new()

# Winget apps (install per-ID for clearer output and retries)
$wingetApps = @(
    'Dropbox.Dropbox', 'FSFhu.Hunspell', 'Google.GoogleDrive', 'Helvesec.RMUX',
    'HTTPie.HTTPie', 'IJHack.QtPass', 'LGUG2Z.masir', 'lin-ycv.EverythingCmdPal',
    'marlocarlo.psmux', 'Microsoft.PowerShell', 'Microsoft.PowerToys',
    'Microsoft.VisualStudio.BuildTools', 'Microsoft.VisualStudioCode',
    'Microsoft.WindowsTerminal', 'Tailscale.Tailscale', 'VideoLAN.VLC', 'WinFsp.WinFsp'
)
# Installer arguments for packages that need more than the default install.
$wingetOverrides = @{
    'Microsoft.VisualStudio.BuildTools' = @('--override', '--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
}

if (Test-Command 'winget') {
    Write-Info 'Installing applications via winget...'
    foreach ($id in $wingetApps) {
        if (-not (Install-WingetPackage -Id $id -Override $wingetOverrides[$id])) {
            $packageFailures.Add("winget:$id")
        }
    }
    # tailscale login needs the Tailscale service (tailscaled) running.
    $tailscaled = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
    if ($tailscaled -and ($tailscaled.Status -ne 'Running' -or $tailscaled.StartType -ne 'Automatic')) {
        Write-Info 'Requesting administrator approval to enable and start the Tailscale service...'
        Invoke-IfNotDryRun {
            if ($null -eq (Invoke-Elevated '-NoProfile', '-Command', 'Set-Service -Name Tailscale -StartupType Automatic -Status Running')) {
                Write-Warn 'Tailscale service was not started (elevation declined); run: Start-Service Tailscale'
            }
        }
    }
}
else {
    Write-Warn 'winget not found; skipping winget apps.'
}

$scoopBuckets = @('extras')
$scoopAppsMain = @(
    '7zip', 'ag', 'antigravity-cli', 'aspell', 'atuin', 'bat', 'bitwarden-cli',
    'bottom', 'broot', 'btop', 'bun', 'busybox', 'clink', 'clink-completions', 'cmake',
    'curl', 'delta', 'direnv', 'dust', 'everything-cli', 'eza', 'far', 'fastfetch',
    'fd', 'ffmpeg', 'fzf', 'gcc', 'gdu', 'gh', 'ghostscript', 'git', 'git-crypt',
    'gitui', 'glow', 'gnupg', 'go', 'gping', 'helix', 'imagemagick', 'jq', 'lazygit',
    'less', 'lsd', 'lua', 'luarocks', 'mosh-client', 'msys2', 'navi', 'neovim',
    'nodejs-lts', 'ouch', 'pandoc', 'pkgconf', 'poppler', 'prek', 'procs', 'pwsh',
    'python', 'rclone', 'ripgrep', 'rtk', 'rustup', 'sd', 'sed', 'shellcheck', 'shfmt',
    'sqlite', 'starship', 'sysinternals', 'tealdeer', 'tectonic', 'texlab',
    'tree-sitter', 'uv', 'vale', 'vim', 'watchexec', 'wget', 'xh', 'yazi', 'yt-dlp',
    'zellij', 'zoxide'
)
$scoopAppsExtras = @(
    'activitywatch', 'antigravity-ide', 'autohotkey', 'bitwarden', 'chatgpt', 'claude',
    'everything', 'everything-powertoys', 'gitu', 'googlechrome', 'gpg4win',
    'handbrake', 'herdr', 'kanata', 'komorebi', 'mupdf', 'notepadplusplus', 'quarto',
    'television', 'thorium-reader', 'totalcommander', 'wezterm', 'winrar', 'yasb', 'zed'
)
$uvTools = @('tmuxp')
$bunApps = @(
    '@anthropic-ai/claude-code@latest', '@github/copilot',
    '@github/copilot-language-server', '@google/gemini-cli@latest',
    '@marp-team/marp-cli', '@openai/codex@latest', 'bibtex-tidy',
    'dockerfile-language-server-nodejs', 'js-beautify', 'oh-my-pi', 'opencode-ai',
    'pi-coding-agent', 'prettier', 'typescript', 'typescript-formatter',
    'typescript-language-server', 'vim-language-server', 'vscode-json-languageserver',
    'yaml-language-server'
)

if (Test-Command 'scoop') {
    Write-Info 'Ensuring scoop buckets and apps are installed...'
    $existingBuckets = @(scoop bucket list).Name
    foreach ($b in $scoopBuckets) {
        if ($b -notin $existingBuckets) {
            Write-Info "scoop bucket add $b"
            if (-not (Invoke-NativeCommand -Description "Scoop bucket $b" -Action { scoop bucket add $b })) {
                $packageFailures.Add("scoop bucket:$b")
            }
        }
    }
    foreach ($app in $scoopAppsMain + $scoopAppsExtras) {
        if (-not (Install-ScoopPackage -Name $app)) {
            $packageFailures.Add("scoop:$app")
        }
    }
    # Apps no bucket ships yet, installed from manifests kept in this repo.
    # checkver bumps each manifest's version/url/hash to its latest release
    # first (visible as a git diff), so the loop below installs the new version.
    $manifestDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scoop'
    $checkver = Join-Path (scoop prefix scoop) 'bin\checkver.ps1'
    if (Test-Path -LiteralPath $checkver) {
        Write-Info 'Checking repo scoop manifests for new versions'
        Invoke-IfNotDryRun {
            # Scoop's scripts read absent config keys, which our strict mode rejects.
            try { & { Set-StrictMode -Off; & $checkver -App '*' -Dir $manifestDir -Update -SkipUpdated } }
            catch { Write-Warn "checkver failed; installing manifests as they are: $_" }
        }
    }
    foreach ($manifest in Get-ChildItem -Path $manifestDir -Filter '*.json') {
        if (-not (Install-ScoopPackage -Name $manifest.BaseName -Source $manifest.FullName)) {
            $packageFailures.Add("scoop:$($manifest.BaseName)")
        }
    }
    # Everything reads the NTFS index through its service, so the app itself
    # runs unelevated with no UAC prompt at each start. Register it once.
    $everything = Join-Path $ScoopRoot 'apps\everything\current\Everything.exe'
    if ((Test-Path -LiteralPath $everything) -and -not (Get-Service -Name Everything -ErrorAction SilentlyContinue)) {
        Write-Info 'Requesting administrator approval to install the Everything service...'
        Invoke-IfNotDryRun {
            if ($null -eq (Invoke-Elevated '-install-service' $everything)) {
                Write-Warn 'Everything service was not installed (elevation declined); Everything will ask for admin rights to index.'
            }
        }
    }
    # Clink (fish-style line editing for cmd.exe, configs in config\clink\) hooks into
    # every cmd window through cmd's per-user AutoRun; re-running is harmless.
    if (Test-Command 'clink') {
        Write-Info 'Enabling Clink in cmd.exe (AutoRun)'
        if (-not (Invoke-NativeCommand -Description 'Clink AutoRun' -Action { clink autorun install })) {
            $packageFailures.Add('clink:autorun')
        }
    }
    # `file` comes from Git's MSYS build: Scoop's file package rejects `--`,
    # which Yazi passes when detecting file types, so every preview was blank.
    $gitFile = Join-Path $HOME 'scoop\apps\git\current\usr\bin\file.exe'
    if (Test-Path -LiteralPath $gitFile) {
        if (-not (Invoke-NativeCommand -Description 'Scoop shim file' -Action { scoop shim add file $gitFile })) {
            $packageFailures.Add('scoop shim:file')
        }
    }

    # fswatch has no Windows release or Scoop package; built from source in MSYS2.
    # ponytail: skipped once installed; bump -Version in Install-Fswatch.ps1 to upgrade.
    Write-Info 'Building fswatch (MSYS2)'
    if (-not (Invoke-NativeCommand -Description 'fswatch build' -Action { & (Join-Path $PSScriptRoot 'Install-Fswatch.ps1') })) {
        $packageFailures.Add('build:fswatch')
    }

    # Scoop's rustup ships no toolchain; install stable so cargo/rustc work.
    # (CopilotChat's tiktoken_core is fetched by its lazy.nvim build step.)
    if (Test-Command 'rustup') {
        Write-Info 'rustup default stable'
        if (-not (Invoke-NativeCommand -Description 'Rust stable toolchain' -Action { rustup default stable })) {
            $packageFailures.Add('rustup:stable')
        }
    }

    if (Test-Command 'bun') {
        foreach ($app in $bunApps) {
            Write-Info "bun add --global $app"
            if (-not (Invoke-NativeCommand -Description "Bun package $app" -Action { bun add --global $app })) {
                $packageFailures.Add("bun:$app")
            }
        }
    }
    else {
        Write-Warn 'bun not found after Scoop installation; skipping Bun packages.'
    }

    # tmuxp: tmux session templates, run against rmux (rmux\tmux.cmd) or psmux.
    if (Test-Command 'uv') {
        foreach ($tool in $uvTools) {
            Write-Info "uv tool install $tool"
            if (-not (Invoke-NativeCommand -Description "uv tool $tool" -Action { uv tool install $tool })) {
                $packageFailures.Add("uv:$tool")
            }
        }
    }
    else {
        Write-Warn 'uv not found after Scoop installation; skipping uv tools.'
    }
}
else {
    Write-Warn 'scoop not found; run setup\Bootstrap.ps1 first. Skipping scoop apps.'
}

# No package manager ships VirtualDesktopAccessor, so fetch the pinned release
# and verify its hash before anything loads it.
# ponytail: pinned to one release; bump URL + hash after a Windows build breaks it.
$vdaUrl = 'https://github.com/Ciantic/VirtualDesktopAccessor/releases/download/2024-12-16-windows11/VirtualDesktopAccessor.dll'
$vdaHash = '8740C572A1C000E3B87FFEB1E4C397EAE9AF3BD4A2ABDC3BCFFACAB4493F8FF5'
$vdaPath = Join-Path $env:LOCALAPPDATA 'VirtualDesktopAccessor\VirtualDesktopAccessor.dll'
if ((Test-Path -LiteralPath $vdaPath) -and (Get-FileHash -LiteralPath $vdaPath -Algorithm SHA256).Hash -eq $vdaHash) {
    Write-Verbose "VirtualDesktopAccessor already installed: $vdaPath"
}
else {
    Write-Info "Downloading VirtualDesktopAccessor to $vdaPath"
    Invoke-IfNotDryRun {
        try {
            New-Item -ItemType Directory -Path (Split-Path -Parent $vdaPath) -Force | Out-Null
            $download = "$vdaPath.download"
            Invoke-WebRequest -Uri $vdaUrl -OutFile $download
            if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $vdaHash) {
                Remove-Item -LiteralPath $download -Force
                throw 'SHA256 mismatch.'
            }
            Move-Item -LiteralPath $download -Destination $vdaPath -Force
        }
        catch {
            Write-Warn "VirtualDesktopAccessor download failed: $_"
            $packageFailures.Add('download:VirtualDesktopAccessor')
        }
    }
}

if (-not (Test-Command Install-Module)) {
    Write-Warn 'Install-Module not available; skipping PS module installs.'
}
else {
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

if ($packageFailures.Count -gt 0) {
    throw "Package installation failed: $($packageFailures -join ', ')"
}

Write-Info 'Package installation step complete.'
