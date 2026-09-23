<#
Configures the user environment variables used by this dotfiles setup.

Usage:
  pwsh -File .\setup\Configure-Env.ps1
  pwsh -File .\setup\Configure-Env.ps1 -DryRun
#>

param(
    [switch]$DryRun,
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

function Set-HomeEnvironment {
    $currentUserHome = [Environment]::GetEnvironmentVariable('HOME', 'User')
    if ($currentUserHome -ne $HOME) {
        Write-Info "Setting user environment variable HOME=$HOME"
        Invoke-IfNotDryRun { [Environment]::SetEnvironmentVariable('HOME', $HOME, 'User') }
    }
    else {
        Write-Info 'HOME already set at user scope.'
    }
}

function Add-UserBinToPath {
    $binDirectory = Join-Path $HOME 'bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = @($userPath -split ';' | Where-Object { $_ })
    if ($pathEntries -notcontains $binDirectory) {
        Write-Info "Adding $binDirectory to the user PATH"
        Invoke-IfNotDryRun { [Environment]::SetEnvironmentVariable('Path', (($pathEntries + $binDirectory) -join ';'), 'User') }
    }
}

# YASB reads its config from the folder in YASB_CONFIG_HOME. Default to the
# noctalia theme; scripts\Set-YasbTheme.ps1 switches it later.
function Set-YasbTheme {
    if ([Environment]::GetEnvironmentVariable('YASB_CONFIG_HOME', 'User')) { return }
    $theme = Join-Path (Split-Path -Parent $PSScriptRoot) 'yasb\themes\noctalia'
    Write-Info "Setting user environment variable YASB_CONFIG_HOME=$theme"
    Invoke-IfNotDryRun { [Environment]::SetEnvironmentVariable('YASB_CONFIG_HOME', $theme, 'User') }
}

Set-HomeEnvironment
Add-UserBinToPath
Set-YasbTheme
