<#
Installs and initializes the Doom and Spacemacs distributions.
#>

param(
    [switch]$DryRun,
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

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
        Write-Info "Creating framework directory: $parent"
        Invoke-IfNotDryRun { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }

    Write-Info "Cloning $Name framework..."
    if (-not (Invoke-NativeCommand -Description "$Name framework" -Action { git clone --depth=1 $Repository $Destination | Out-Null })) {
        throw "Unable to clone the $Name framework."
    }

    return $true
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$dotfilesEmacs = Join-Path $HOME 'dotfiles\emacs'
if (-not (Test-Path -LiteralPath $dotfilesEmacs)) {
    Write-Warn "Shared Emacs profiles not found at $dotfilesEmacs; skipping Emacs distribution setup."
    return
}

$roots = Get-EmacsRoots
$emacsConfigRoot = $roots.ConfigRoot
$emacsDataRoot = $roots.DataRoot
$emacsStateRoot = $roots.StateRoot
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
    $doomProfileScript = Join-Path $repoRoot 'scripts\Doom-Profile.ps1'

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
