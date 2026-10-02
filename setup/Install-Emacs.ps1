<#
Installs and initializes the Doom and Spacemacs distributions.
#>

[CmdletBinding()]
param(
    [switch]$DryRun
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
        [string]$Destination,

        [string]$Upstream,

        [int]$Depth = 1
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
    if (-not (Invoke-NativeCommand -Description "$Name framework" -Action { git clone "--depth=$Depth" $Repository $Destination | Out-Null })) {
        throw "Unable to clone the $Name framework."
    }
    if ($Upstream) {
        Invoke-IfNotDryRun { git -C $Destination remote add upstream $Upstream }
    }

    return $true
}

$dotfilesEmacs = Join-Path $DotfilesRoot 'emacs'
if (-not (Test-Path -LiteralPath $dotfilesEmacs)) {
    Write-Warn "Shared Emacs profiles not found at $dotfilesEmacs; skipping Emacs distribution setup."
    return
}

$roots = Get-EmacsRoots
$doomFramework = (Get-ProfilePaths 'doom').Framework
$spacemacs = Get-ProfilePaths 'spacemacs'
$spacemacsFramework = $spacemacs.Framework

[void](Ensure-GitCheckout -Name 'Doom' -Repository 'https://github.com/doomemacs/doomemacs.git' -Destination $doomFramework)
[void](Ensure-GitCheckout -Name 'Spacemacs' -Repository 'git@github.com:aam-at/spacemacs.git' -Upstream 'https://github.com/syl20bnr/spacemacs.git' -Depth 16 -Destination $spacemacsFramework)

if ($DryRun) {
    Write-Info 'Doom and Spacemacs installs would open in separate terminal windows.'
    return
}

# Runs a framework's first install in its own terminal window so the slow
# package downloads don't block the rest of setup; the marker is written only
# when the install exits 0, so a failed one is retried on the next run.
function Start-FrameworkInstall([string]$Name, [string]$Command) {
    $marker = Join-Path $roots.StateRoot "$Name\.windots-installed"
    if (Test-Path -LiteralPath (Join-Path $roots.ConfigRoot "$Name\init.el")) {
        if (Test-Path -LiteralPath $marker) {
            Write-Info "$Name initial installation already completed."
            return
        }
        Write-Info "Installing $Name packages in a separate terminal window..."
        $script = "`$Host.UI.RawUI.WindowTitle = '$Name install'; $Command; " +
        "if (`$LASTEXITCODE -eq 0) { New-Item -ItemType Directory -Force '$(Split-Path -Parent $marker)' | Out-Null; " +
        "Set-Content -LiteralPath '$marker' -Value 'Installed by windots Setup.ps1' -NoNewline; '$Name installed.' } " +
        "else { Write-Host '$Name installation failed; rerun Install-Emacs.ps1.' -ForegroundColor Red }"
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $script)
    }
    else {
        Write-Warn "$Name profile is not linked at $($roots.ConfigRoot)\$Name; skipping $Name installation."
    }
}

$doomProfileScript = WindotsPath 'scripts\Doom-Profile.ps1'
Start-FrameworkInstall 'doom' "& '$doomProfileScript' install --force"
# Loading Spacemacs in batch mode installs its layers' packages, then exits.
Start-FrameworkInstall 'spacemacs' ("`$env:SPACEMACSDIR = '$($spacemacs.Environment.SPACEMACSDIR)'; " +
    "emacs --batch --init-directory='$spacemacsFramework' -l '$(Join-Path $spacemacsFramework 'init.el')'")
