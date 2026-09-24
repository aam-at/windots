<#
Installs applications via winget, Scoop, and Bun, plus PowerShell modules and
VirtualDesktopAccessor.dll (used by shells\native\Native-Desktop.ahk).

Usage:
  pwsh -File .\setup\Install-Apps.ps1
  pwsh -File .\setup\Install-Apps.ps1 -DryRun

Scoop is the primary package manager for portable applications. Run
setup\Bootstrap.ps1 first on a machine that doesn't have it yet.
#>

param(
    [switch]$DryRun,
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

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
    # Source is a bucket app name or a manifest path (for scoop\*.json in this repo).
    param([Parameter(Mandatory)][string]$Name, [string]$Source = $Name)

    scoop prefix $Name *>$null
    if ($LASTEXITCODE -eq 0) {
        Write-DebugInfo "scoop package is installed; checking for updates: $Name"
        return Invoke-NativeCommand -Description "Scoop package update $Name" -Action { scoop update $Name }
    }

    Write-Info "scoop install $Source"
    return Invoke-NativeCommand -Description "Scoop package $Name" -Action { scoop install $Source }
}

$packageFailures = [System.Collections.Generic.List[string]]::new()

# Winget apps (install per-ID for clearer output and retries)
$wingetApps = @(
    'Dropbox.Dropbox', 'FSFhu.Hunspell', 'HTTPie.HTTPie', 'IJHack.QtPass', 'LGUG2Z.masir', 'Microsoft.PowerShell', 'Microsoft.PowerToys',
    'lin-ycv.EverythingCmdPal',
    'Microsoft.VisualStudio.BuildTools', 'Microsoft.VisualStudioCode', 'Microsoft.WindowsTerminal',
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

$scoopBuckets = @('extras')
$scoopAppsMain = @(
    '7zip', 'ag', 'aspell', 'bat', 'bitwarden-cli', 'bottom', 'broot', 'btop', 'bun', 'busybox', 'clink', 'clink-completions', 'cmake', 'curl', 'everything-cli',
    'delta', 'direnv', 'dust', 'eza', 'far', 'fastfetch', 'fd', 'ffmpeg', 'fzf', 'gcc', 'gdu', 'gh', 'ghostscript', 'git', 'gitui',
    'glow', 'gnupg', 'go', 'gping', 'git-crypt', 'helix', 'imagemagick', 'jq', 'lazygit', 'lsd', 'lua', 'luarocks', 'mosh-client', 'msys2',
    'navi', 'neovim', 'nodejs-lts', 'ouch', 'pandoc', 'pkgconf', 'prek', 'procs', 'pwsh', 'python', 'ripgrep', 'rustup',
    'rclone', 'sd', 'sed', 'shellcheck', 'shfmt', 'sqlite', 'starship', 'sysinternals', 'tealdeer', 'tectonic', 'texlab',
    'tree-sitter', 'uv', 'vale', 'vim', 'watchexec', 'wget', 'xh', 'yazi', 'yt-dlp', 'zellij', 'zoxide'
)
$scoopAppsExtras = @(
    'activitywatch', 'antigravity-ide', 'autohotkey', 'bitwarden', 'chatgpt', 'claude', 'emacs', 'everything', 'everything-powertoys', 'gitu', 'googlechrome', 'gpg4win', 'handbrake', 'herdr', 'kanata',
    'komokana', 'komorebi', 'mupdf', 'notepadplusplus', 'television', 'totalcommander', 'vlc', 'wezterm',
    'quarto', 'winrar', 'windows-virtualdesktop-helper', 'yasb', 'zed'
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
    $scoopRoot = if ([string]::IsNullOrWhiteSpace($env:SCOOP)) { Join-Path $HOME 'scoop' } else { $env:SCOOP }
    foreach ($b in $scoopBuckets) {
        $bucketExists = (scoop bucket list | Out-String) -match "(?m)^$([regex]::Escape($b))\s"
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
            try { & $checkver -App '*' -Dir $manifestDir -Update -SkipUpdated }
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
            try { Start-Process -FilePath $everything -ArgumentList '-install-service' -Verb RunAs -Wait }
            catch { Write-Warn 'Everything service was not installed (elevation declined); Everything will ask for admin rights to index.' }
        }
    }
    # Clink (fish-style line editing for cmd.exe, configs in clink\) hooks into
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
    Write-DebugInfo "VirtualDesktopAccessor already installed: $vdaPath"
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
