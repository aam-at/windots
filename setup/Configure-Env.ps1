<#
Configures the user environment used by this dotfiles setup: environment
variables, keyboard languages (English US + Russian), and Singapore regional
formats, home location and time zone.

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

# ~/bin leads the user PATH so its wrappers (cmd\herdr.cmd) win over Scoop's
# shims of the same name.
function Add-UserBinToPath {
    $binDirectory = Join-Path $HOME 'bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = @($userPath -split ';' | Where-Object { $_ })
    if ($pathEntries[0] -ne $binDirectory) {
        Write-Info "Putting $binDirectory first on the user PATH"
        $others = @($pathEntries | Where-Object { $_ -ne $binDirectory })
        Invoke-IfNotDryRun { [Environment]::SetEnvironmentVariable('Path', ((@($binDirectory) + $others) -join ';'), 'User') }
    }
}

# DOTFILES and WINDOTS locate the two checkouts for setup scripts, the
# PowerShell profile and any other tool. Existing values are kept.
function Set-RepoLocations {
    $locations = [ordered]@{ DOTFILES = $DotfilesRoot; WINDOTS = (Split-Path -Parent $PSScriptRoot) }
    foreach ($name in $locations.Keys) {
        if ([Environment]::GetEnvironmentVariable($name, 'User')) { continue }
        Write-Info "Setting user environment variable $name=$($locations[$name])"
        Invoke-IfNotDryRun { [Environment]::SetEnvironmentVariable($name, $locations[$name], 'User') }
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

# Keyboard languages and region. Windows has no Singapore display language,
# so the UI stays English (United States) and Singapore sets formats, home
# location and time zone. The International module only works properly in
# Windows PowerShell, so run it there. Each call is idempotent.
function Set-RegionalSettings {
    Write-Info 'Setting keyboards (English US, Russian) and Singapore formats, location and time zone'
    $script = @'
$languages = New-WinUserLanguageList en-US
$languages.Add('ru-RU')
Set-WinUserLanguageList $languages -Force
Set-Culture en-SG
Set-WinHomeLocation -GeoId 215
Set-TimeZone -Id 'Singapore Standard Time'
'@
    if (-not (Invoke-NativeCommand -Description 'Regional settings' -Action { powershell -NoProfile -NonInteractive -Command $script })) {
        Write-Warn 'Keyboard languages or regional settings were not applied.'
    }
}

Set-HomeEnvironment
Set-RepoLocations
Add-UserBinToPath
Set-YasbTheme
Set-RegionalSettings
