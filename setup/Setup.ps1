<#
=================================================================
 Windows Setup Script (refactored)
 - Installs common tools via winget and Scoop
 - Creates idempotent links to config files and folders
 - Safer fallbacks for link creation (junction/hardlink/copy)
 Run as a regular user; it prompts for UAC approval only for the one
 step that needs it (Sudo, Developer Mode, long paths, the agent
 power plan). Decline the prompt to skip just that step.
 Usage examples:
   pwsh -ExecutionPolicy Bypass -File .\setup\Setup.ps1
   pwsh -File .\setup\Setup.ps1 -SkipPackages
   pwsh -File .\setup\Setup.ps1 -DryRun
   pwsh -File .\setup\Setup.ps1 -LogLevel Debug
   pwsh -File .\setup\Setup.ps1 -DesktopMode Native
=================================================================
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
    [ValidateSet('Native', 'Komorebi')]
    [string]$DesktopMode = 'Native',
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

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
        Write-Info 'Requesting administrator approval to enable Developer Mode, long paths, persistent ssh-agent, and the agent power plan...'
        $registryArgs = @{ LogLevel = $LogLevel; DryRun = [bool]$DryRun }
        if (-not (Invoke-ElevatedScript -ScriptPath (Join-Path $PSScriptRoot 'Configure-Registry.ps1') -Arguments $registryArgs)) {
            Write-Warn 'Admin-only registry, ssh-agent, and power-plan settings were skipped (elevation declined or failed). Symlink creation may require Developer Mode to be enabled manually.'
        }
    }
}

# -----------------------
# Execution
# -----------------------
try {
    if ($SkipEnv) { Write-Info 'Skipping environment configuration.' } else { Invoke-Step 'Configure-Env' }
    if ($SkipRegistry) { Write-Info 'Skipping registry configuration.' } else { Configure-Registry }
    if ($SkipSsh) { Write-Info 'Skipping SSH agent configuration.' } else { Invoke-Step 'Configure-SshKey' }
    if ($SkipPowerToys) { Write-Info 'Skipping PowerToys configuration.' } else { Invoke-Step 'Configure-PowerToys' }
    if ($SkipPackages) { Write-Info 'Skipping package installation.' } else { Invoke-Step 'Install-Apps' }
    if ($SkipLinks) { Write-Info 'Skipping link installation.' } else { Invoke-Step 'Install-Links' @{ DesktopMode = $DesktopMode; Force = [bool]$Force } }
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
