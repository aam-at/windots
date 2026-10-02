<#
Configures PowerToys productivity settings. config/powertoys/settings.json lists every
module, so modules this setup doesn't use stay off instead of running at their
defaults. FancyZones is off with -DesktopMode Komorebi, which tiles windows itself.
#>

[CmdletBinding()]
param(
    [ValidateSet('Native', 'Komorebi')]
    [string]$DesktopMode = 'Native',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$powerToysExe = Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe'
if (-not (Test-Path -LiteralPath $powerToysExe)) {
    Write-Warn 'PowerToys is not installed; skipping PowerToys configuration.'
    return
}

# Merges a repo template into the live settings file, keeping every other key.
function Merge-Object($Destination, $Source) {
    foreach ($p in $Source.PSObject.Properties) {
        $d = $Destination.PSObject.Properties[$p.Name]
        if ($d -and $d.Value -is [pscustomobject] -and $p.Value -is [pscustomobject]) { Merge-Object $d.Value $p.Value }
        else { $Destination | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
    }
}
$templatePath = WindotsPath 'config\powertoys\settings.json'
$settingsPath = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\settings.json'
if (-not (Test-Path -LiteralPath $templatePath)) {
    Write-Warn "PowerToys settings template not found: $templatePath"
    return
}

try {
    $template = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json
    $settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json } else { [pscustomobject]@{} }
    Merge-Object $settings $template
    if ($DesktopMode -eq 'Komorebi') { $settings.enabled.FancyZones = $false }
    # Deep enough for Command Palette's nested dock/provider settings;
    # ConvertTo-Json silently flattens anything deeper.
    $settingsJson = $settings | ConvertTo-Json -Depth 32

    $settingsDirectory = Split-Path -Parent $settingsPath
    if (-not (Test-Path -LiteralPath $settingsDirectory)) {
        Write-Info "Creating PowerToys settings directory: $settingsDirectory"
        Invoke-IfNotDryRun { New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null }
    }

    if ((Test-Path -LiteralPath $settingsPath) -and (-not (Test-Path -LiteralPath "$settingsPath.windots-backup"))) {
        Write-Info "Backing up PowerToys settings: $settingsPath.windots-backup"
        Invoke-IfNotDryRun { Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.windots-backup" -ErrorAction Stop }
    }

    Write-Info 'Applying PowerToys settings...'
    Invoke-IfNotDryRun { Set-Content -LiteralPath $settingsPath -Value $settingsJson -Encoding utf8 -NoNewline }
}
catch {
    Write-Warn "Failed to configure PowerToys: $_"
}
Write-Info 'PowerToys settings saved. Restart PowerToys to apply them to the current session.'
