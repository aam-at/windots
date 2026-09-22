<#
Configures PowerToys productivity settings.
#>

param(
    [switch]$DryRun,
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$powerToysExe = Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe'
if (-not (Test-Path -LiteralPath $powerToysExe)) {
    Write-Warn 'PowerToys is not installed; skipping PowerToys configuration.'
    return
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repoRoot 'powertoys\settings.json'
$settingsDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys'
$settingsPath = Join-Path $settingsDirectory 'settings.json'
if (-not (Test-Path -LiteralPath $templatePath)) {
    Write-Warn "PowerToys settings template not found: $templatePath"
    return
}

try {
    $template = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json
    if (Test-Path -LiteralPath $settingsPath) {
        $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    }
    else {
        $settings = [pscustomobject]@{}
    }

    Merge-ObjectProperties -Destination $settings -Source $template
    $settingsJson = $settings | ConvertTo-Json -Depth 10

    if (-not (Test-Path -LiteralPath $settingsDirectory)) {
        Write-Info "Creating PowerToys settings directory: $settingsDirectory"
        Invoke-IfNotDryRun { New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null }
    }

    if ((Test-Path -LiteralPath $settingsPath) -and (-not (Test-Path -LiteralPath "$settingsPath.windots-backup"))) {
        Write-Info "Backing up PowerToys settings: $settingsPath.windots-backup"
        Invoke-IfNotDryRun { Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.windots-backup" -ErrorAction Stop }
    }

    Write-Info 'Applying PowerToys productivity settings...'
    Invoke-IfNotDryRun { Set-Content -LiteralPath $settingsPath -Value $settingsJson -Encoding utf8 -NoNewline }
    Write-Info 'PowerToys settings saved. Restart PowerToys to apply them to the current session.'
}
catch {
    Write-Warn "Failed to configure PowerToys: $_"
}
