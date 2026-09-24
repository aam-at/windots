<#
Runs every setup step in order; each step is its own script in this folder
and can be re-run alone with the same -DryRun/-LogLevel switches. The first
column is the name to pass to -Skip (comma-separated, e.g. -Skip Apps,Fonts):

  Env        Configure-Env       HOME, ~/bin on PATH, keyboards (EN-US, RU),
                                 Singapore region
  Registry   Configure-Registry  Explorer tweaks; with UAC: Sudo, Developer
                                 Mode, long paths, lid/sleep power plan
  Ssh        Configure-SshAgent  enable ssh-agent (UAC), load ~/.ssh/id_ed25519
  Apps       Install-Apps        winget, Scoop, Bun packages, PowerShell modules
  PowerToys  Configure-PowerToys merge powertoys/settings.json
  Links      Install-Links       link configs from this repo and ~/dotfiles
  Startup    Install-Startup     Startup shortcuts for -DesktopMode, plus YASB,
                                 thide and Kanata
  Emacs      Install-Emacs       Doom and Spacemacs frameworks
  Fonts      Install-Fonts       clone and install font repositories

Expects Scoop, Git and ~/dotfiles (Bootstrap.ps1 sets those up). Run as a
regular user; only Configure-Registry and Configure-SshAgent prompt for UAC.

Usage:
  pwsh -ExecutionPolicy Bypass -File .\setup\Setup.ps1
  pwsh -File .\setup\Setup.ps1 -DryRun -Skip Apps,Fonts
  pwsh -File .\setup\Setup.ps1 -DesktopMode Komorebi
#>

param(
    [switch]$DryRun,
    [switch]$Force,
    # Step names from $steps below; pwsh -File passes "a,b" as one string.
    [string[]]$Skip = @(),
    [ValidateSet('Native', 'Komorebi')]
    [string]$DesktopMode = 'Native',
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

# Runs a script elevated (UAC prompt) with -Name value / -Switch arguments;
# returns whether it exited 0. False when elevation is declined.
function Invoke-ElevatedScript([string]$ScriptPath, [hashtable]$Arguments = @{}) {
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
    foreach ($entry in $Arguments.GetEnumerator()) {
        if ($entry.Value -is [bool] -or $entry.Value -is [switch]) { if ($entry.Value) { $argumentList += "-$($entry.Key)" } }
        else { $argumentList += "-$($entry.Key)", "$($entry.Value)" }
    }
    try { (Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argumentList -Verb RunAs -Wait -PassThru).ExitCode -eq 0 }
    catch { $false }
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
        if (-not (Invoke-ElevatedScript (Join-Path $PSScriptRoot 'Configure-Registry.ps1') $registryArgs)) {
            Write-Warn 'Admin-only registry and power-plan settings were skipped (elevation declined or failed). Symlink creation may require Developer Mode to be enabled manually.'
        }
    }
}

try {
    $steps = [ordered]@{
        Env       = { Invoke-Step 'Configure-Env' }
        Registry  = { Configure-Registry }
        Ssh       = { Invoke-Step 'Configure-SshAgent' }
        Apps      = { Invoke-Step 'Install-Apps' }
        PowerToys = { Invoke-Step 'Configure-PowerToys' }
        Links     = { Invoke-Step 'Install-Links' @{ Force = [bool]$Force } }
        Startup   = { Invoke-Step 'Install-Startup' @{ DesktopMode = $DesktopMode } }
        Emacs     = { Invoke-Step 'Install-Emacs' }
        Fonts     = { Invoke-Step 'Install-Fonts' }
    }
    $Skip = @($Skip -split ',' | ForEach-Object Trim | Where-Object { $_ })
    $unknown = @($Skip | Where-Object { $_ -notin $steps.Keys })
    if ($unknown) { throw "Unknown -Skip step(s): $($unknown -join ', '). Valid: $($steps.Keys -join ', ')." }
    foreach ($step in $steps.GetEnumerator()) {
        if ($step.Key -in $Skip) { Write-Info "Skipping $($step.Key)." } else { & $step.Value }
    }
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
