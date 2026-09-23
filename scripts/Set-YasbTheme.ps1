<#
Switches the YASB bar theme. Each theme is a folder under yasb\themes with its
own config.yaml and styles.css; YASB reads the folder named by the user
environment variable YASB_CONFIG_HOME, so switching sets that and restarts YASB.

Usage:
  pwsh -File .\scripts\Set-YasbTheme.ps1            # list themes, mark the active one
  pwsh -File .\scripts\Set-YasbTheme.ps1 noctalia
#>

param([string]$Name)

$ErrorActionPreference = 'Stop'
$themesRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'yasb\themes'
$active = [Environment]::GetEnvironmentVariable('YASB_CONFIG_HOME', 'User')

if (-not $Name) {
    foreach ($theme in Get-ChildItem -LiteralPath $themesRoot -Directory) {
        $marker = if ($theme.FullName -eq $active) { '*' } else { ' ' }
        Write-Host "$marker $($theme.Name)"
    }
    return
}

$themeDir = Join-Path $themesRoot $Name
if (-not (Test-Path -LiteralPath (Join-Path $themeDir 'config.yaml'))) {
    throw "No such theme: $Name (see: pwsh -File $PSCommandPath)"
}

[Environment]::SetEnvironmentVariable('YASB_CONFIG_HOME', $themeDir, 'User')
$env:YASB_CONFIG_HOME = $themeDir
Write-Host "YASB theme: $Name"

# Restart so YASB picks up the new folder; it inherits $env:YASB_CONFIG_HOME.
Get-Process -Name yasb -ErrorAction SilentlyContinue | Stop-Process -Force
$yasb = Get-Command yasb -CommandType Application -ErrorAction SilentlyContinue
if ($yasb) { Start-Process -FilePath $yasb.Source -WindowStyle Hidden }
