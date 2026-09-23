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

# Merges a repo template into a live settings file, keeping every other key.
function Merge-SettingsFile([string]$Name, [string]$TemplatePath, [string]$SettingsPath) {
    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        Write-Warn "$Name settings template not found: $TemplatePath"
        return
    }

    try {
        $template = Get-Content -Raw -LiteralPath $TemplatePath | ConvertFrom-Json
        $settings = if (Test-Path -LiteralPath $SettingsPath) { Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json } else { [pscustomobject]@{} }
        Merge-ObjectProperties -Destination $settings -Source $template
        # Deep enough for Command Palette's nested dock/provider settings;
        # ConvertTo-Json silently flattens anything deeper.
        $settingsJson = $settings | ConvertTo-Json -Depth 32

        $settingsDirectory = Split-Path -Parent $SettingsPath
        if (-not (Test-Path -LiteralPath $settingsDirectory)) {
            Write-Info "Creating $Name settings directory: $settingsDirectory"
            Invoke-IfNotDryRun { New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null }
        }

        if ((Test-Path -LiteralPath $SettingsPath) -and (-not (Test-Path -LiteralPath "$SettingsPath.windots-backup"))) {
            Write-Info "Backing up $Name settings: $SettingsPath.windots-backup"
            Invoke-IfNotDryRun { Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.windots-backup" -ErrorAction Stop }
        }

        Write-Info "Applying $Name settings..."
        Invoke-IfNotDryRun { Set-Content -LiteralPath $SettingsPath -Value $settingsJson -Encoding utf8 -NoNewline }
    }
    catch {
        Write-Warn "Failed to configure ${Name}: $_"
    }
}


Merge-SettingsFile 'PowerToys' (Join-Path $repoRoot 'powertoys\settings.json') (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\settings.json')
Write-Info 'PowerToys settings saved. Restart PowerToys to apply them to the current session.'
