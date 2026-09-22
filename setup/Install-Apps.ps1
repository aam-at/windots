<#
Installs applications via winget, Scoop, and Bun, plus PowerShell modules.

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

$packageFailures = [System.Collections.Generic.List[string]]::new()

# Winget apps (install per-ID for clearer output and retries)
$wingetApps = @(
    'Dropbox.Dropbox', 'FSFhu.Hunspell', 'HTTPie.HTTPie', 'IJHack.QtPass', 'LGUG2Z.masir', 'Microsoft.PowerShell', 'Microsoft.PowerToys',
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
    '7zip', 'ag', 'aspell', 'bat', 'bitwarden-cli', 'bottom', 'broot', 'btop', 'bun', 'busybox', 'cmake', 'curl',
    'delta', 'direnv', 'dust', 'eza', 'far', 'fastfetch', 'fd', 'file', 'ffmpeg', 'fzf', 'gcc', 'gdu', 'gh', 'git', 'gitui',
    'glow', 'gnupg', 'go', 'gping', 'helix', 'jq', 'lazygit', 'lsd', 'lua', 'mosh-client', 'msys2',
    'navi', 'neovim', 'nodejs-lts', 'ouch', 'pandoc', 'prek', 'procs', 'pwsh', 'python', 'ripgrep', 'rustup',
    'rclone', 'sd', 'sed', 'shellcheck', 'shfmt', 'sqlite', 'starship', 'sysinternals', 'tealdeer', 'tectonic', 'texlab',
    'tree-sitter', 'uv', 'vale', 'vim', 'watchexec', 'wget', 'xh', 'yazi', 'yt-dlp', 'zellij', 'zoxide'
)
$scoopAppsExtras = @(
    'activitywatch', 'antigravity-ide', 'autohotkey', 'bitwarden', 'extras/chatgpt', 'extras/claude', 'emacs', 'gitu', 'googlechrome', 'gpg4win', 'handbrake', 'herdr', 'kanata',
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
    Write-Warn 'scoop not found; run setup\Bootstrap.ps1 first. Skipping scoop apps.'
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
