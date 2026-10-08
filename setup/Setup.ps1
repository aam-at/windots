<#
Runs every setup step in order; each step is its own script in this folder
and can be re-run alone with the same -DryRun/-Verbose switches. The first
column is the name to pass to -Skip (comma-separated, e.g. -Skip Apps,Fonts):

  Env        Configure-Env       HOME, ~/.local/bin on PATH, keyboards (EN-US, RU),
                                 Singapore region
  Registry   Configure-Registry  Explorer tweaks; with UAC: Sudo, Developer
                                 Mode, long paths, lid/sleep power plan
  Ssh        Configure-SshAgent  enable ssh-agent (UAC), load ~/.ssh/id_ed25519
  Apps       Install-Apps        winget, Scoop, Bun packages, PowerShell modules
  Msys2      Configure-Msys2     update MSYS2, install gcc/enchant for Emacs jinx
  PowerToys  Configure-PowerToys merge config/powertoys/settings.json (no FancyZones
                                 with -DesktopMode Komorebi)
  Links      Install-Links       link configs from this repo and ~/dotfiles,
                                 install psmux plugins
  Startup    Install-Startup     Startup shortcuts for -DesktopMode, plus YASB,
                                 thide, Kanata and native helpers (psmux-agent)
  Emacs      Install-Emacs       Doom and Spacemacs frameworks
  Fonts      Install-Fonts       clone and install font repositories

Expects Scoop, Git and ~/dotfiles (Bootstrap.ps1 sets those up). Run as a
regular user; only Configure-Registry and Configure-SshAgent prompt for UAC.

Usage:
  pwsh -ExecutionPolicy Bypass -File .\setup\Setup.ps1
  pwsh -File .\setup\Setup.ps1 -DryRun -Skip Apps,Fonts
  pwsh -File .\setup\Setup.ps1 -DesktopMode Komorebi
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    # Step names from $steps below; pwsh -File passes "a,b" as one string.
    [string[]]$Skip = @(),
    [ValidateSet('Native', 'Komorebi')]
    [string]$DesktopMode = 'Native'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

# Runs a sibling setup script with -DryRun; -Verbose reaches it through
# $VerbosePreference.
function Invoke-Step([string]$Name, [hashtable]$Arguments = @{}) {
    if ($DryRun) { $Arguments['DryRun'] = $true }
    & (Join-Path $PSScriptRoot "$Name.ps1") @Arguments
    if (-not $?) { throw "$Name failed." }
}

function Configure-Registry {
    Invoke-Step 'Configure-Registry'
    if (-not (Test-IsAdmin)) {
        Write-Info ('Requesting administrator approval to enable Sudo, Developer ' +
            'Mode, long paths, and the agent power plan...')
        $registryArgs = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $PSScriptRoot 'Configure-Registry.ps1')
        )
        if ($DryRun) { $registryArgs += '-DryRun' }
        if ($VerbosePreference -eq 'Continue') { $registryArgs += '-Verbose' }
        if ((Invoke-Elevated $registryArgs) -ne 0) {
            Write-Warn ('Admin-only registry and power-plan settings were skipped ' +
                '(elevation declined or failed). Symlink creation may require ' +
                'Developer Mode to be enabled manually.')
        }
    }
}

try {
    $steps = [ordered]@{
        Env = { Invoke-Step 'Configure-Env' }
        Registry = { Configure-Registry }
        Ssh = { Invoke-Step 'Configure-SshAgent' }
        Apps = { Invoke-Step 'Install-Apps' }
        Msys2 = { Invoke-Step 'Configure-Msys2' }
        PowerToys = {
            Invoke-Step 'Configure-PowerToys' @{ DesktopMode = $DesktopMode }
        }
        Links = { Invoke-Step 'Install-Links' @{ Force = [bool]$Force } }
        Startup = { Invoke-Step 'Install-Startup' @{ DesktopMode = $DesktopMode } }
        Emacs = { Invoke-Step 'Install-Emacs' }
        Fonts = { Invoke-Step 'Install-Fonts' }
    }
    $Skip = @($Skip -split ',' | ForEach-Object Trim | Where-Object { $_ })
    $unknown = @($Skip | Where-Object { $_ -notin $steps.Keys })
    if ($unknown) {
        throw ("Unknown -Skip step(s): $($unknown -join ', '). " +
            "Valid: $($steps.Keys -join ', ').")
    }
    foreach ($step in $steps.GetEnumerator()) {
        if ($step.Key -in $Skip) {
            Write-Info "Skipping $($step.Key)."
        }
        else { & $step.Value }
    }
    Write-Info 'Script completed successfully.'
}
catch {
    Write-Host "[ERROR] $_" -ForegroundColor Red
    exit 1
}
finally {
    if ($script:Warnings.Count -gt 0) {
        Write-Host ''
        $count = $script:Warnings.Count
        Write-Host "[SUMMARY] Completed with $count warning(s):" -ForegroundColor Yellow
        foreach ($w in $script:Warnings) { Write-Host "  - $w" -ForegroundColor Yellow }
    }
}
