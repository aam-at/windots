<#
Runs every setup step in order; each step is its own script in this folder
and can be re-run alone with the same -DryRun/-LogLevel switches:

  Configure-Env       HOME and ~/bin on the user PATH
  Configure-Registry  Explorer tweaks; with UAC: Sudo, Developer Mode,
                      long paths, lid/sleep power plan
  Configure-SshAgent  enable ssh-agent (UAC), load ~/.ssh/id_ed25519
  Install-Apps        winget, Scoop, Bun packages and PowerShell modules
  Configure-PowerToys merge powertoys/settings.json
  Install-Links       link configs from this repo and ~/dotfiles
  Install-Startup     Startup shortcuts for -DesktopMode, plus Kanata
  Install-Emacs       Doom and Spacemacs frameworks
  Install-Fonts       clone and install font repositories

Expects Scoop, Git and ~/dotfiles (Bootstrap.ps1 sets those up). Run as a
regular user; only Configure-Registry and Configure-SshAgent prompt for UAC.

Usage:
  pwsh -ExecutionPolicy Bypass -File .\setup\Setup.ps1
  pwsh -File .\setup\Setup.ps1 -DryRun -SkipPackages -SkipFonts
  pwsh -File .\setup\Setup.ps1 -DesktopMode Komorebi
#>

param(
    [switch]$DryRun,
    [switch]$Force,
    [switch]$SkipEmacs,
    [switch]$SkipEnv,
    [switch]$SkipFonts,
    [switch]$SkipLinks,
    [switch]$SkipPackages,
    [switch]$SkipPowerToys,
    [switch]$SkipRegistry,
    [switch]$SkipSsh,
    [switch]$SkipStartup,
    [ValidateSet('Native', 'Komorebi')]
    [string]$DesktopMode = 'Native',
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

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

# Runs a sibling setup script with the shared -LogLevel/-DryRun switches.
function Invoke-Step([string]$Name, [hashtable]$Arguments = @{}) {
    $Arguments['LogLevel'] = $LogLevel
    if ($DryRun) { $Arguments['DryRun'] = $true }
    & (Join-Path $PSScriptRoot "$Name.ps1") @Arguments
    if (-not $?) { throw "$Name failed." }
}

function Configure-Registry {
    Invoke-Step 'Configure-Registry'
    if (-not (Test-IsAdmin)) {
        Write-Info 'Requesting administrator approval to enable Sudo, Developer Mode, long paths, and the agent power plan...'
        $registryArgs = @{ LogLevel = $LogLevel; DryRun = [bool]$DryRun }
        if (-not (Invoke-ElevatedScript -ScriptPath (Join-Path $PSScriptRoot 'Configure-Registry.ps1') -Arguments $registryArgs)) {
            Write-Warn 'Admin-only registry and power-plan settings were skipped (elevation declined or failed). Symlink creation may require Developer Mode to be enabled manually.'
        }
    }
}

try {
    if ($SkipEnv) { Write-Info 'Skipping environment configuration.' } else { Invoke-Step 'Configure-Env' }
    if ($SkipRegistry) { Write-Info 'Skipping registry configuration.' } else { Configure-Registry }
    if ($SkipSsh) { Write-Info 'Skipping SSH agent configuration.' } else { Invoke-Step 'Configure-SshAgent' }
    if ($SkipPackages) { Write-Info 'Skipping package installation.' } else { Invoke-Step 'Install-Apps' }
    if ($SkipPowerToys) { Write-Info 'Skipping PowerToys configuration.' } else { Invoke-Step 'Configure-PowerToys' }
    if ($SkipLinks) { Write-Info 'Skipping link installation.' } else { Invoke-Step 'Install-Links' @{ Force = [bool]$Force } }
    if ($SkipStartup) { Write-Info 'Skipping Startup shortcuts.' } else { Invoke-Step 'Install-Startup' @{ DesktopMode = $DesktopMode } }
    if ($SkipEmacs) { Write-Info 'Skipping Emacs installation.' } else { Invoke-Step 'Install-Emacs' }
    if ($SkipFonts) { Write-Info 'Skipping fonts installation.' } else { Invoke-Step 'Install-Fonts' }
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
