<#
Switch to the laptop desktop: native Windows virtual desktops, PowerToys
Workspaces, and FancyZones. Run again whenever PowerToys is updated or its
settings reset.
#>

[CmdletBinding()]
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\setup\Common.ps1')

function Set-PowerToysSetting([string]$Path, [string[]]$EnabledUtilities) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "PowerToys settings not found: $Path" }
    $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($utility in $EnabledUtilities) {
        $settings.enabled.$utility = $true
    }
    Invoke-IfNotDryRun { $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8 -NoNewline }
}

function Set-FancyZonesSettings([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "FancyZones settings not found: $Path" }
    $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $settings.properties.fancyzones_overrideSnapHotkeys.value = $true
    $settings.properties.fancyzones_moveWindowsBasedOnPosition.value = $true
    $settings.properties.fancyzones_quickLayoutSwitch.value = $true
    $settings.properties.fancyzones_flashZonesOnQuickSwitch.value = $false
    Invoke-IfNotDryRun { $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8 -NoNewline }
}

function Set-TaskbarAutoHide {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
    $settings = (Get-ItemProperty -LiteralPath $path -Name Settings).Settings
    if ($settings.Length -le 8) { throw 'Taskbar settings are not in the expected format.' }
    if ($settings[8] -eq 2) { return }

    $settings[8] = 2
    Invoke-IfNotDryRun {
        Set-ItemProperty -LiteralPath $path -Name Settings -Value $settings
        Stop-Process -Name explorer -Force
        Start-Process explorer.exe
    }
}

try {
    $powerToysRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys'
    Set-PowerToysSetting -Path (Join-Path $powerToysRoot 'settings.json') -EnabledUtilities @('FancyZones', 'Workspaces')
    Set-FancyZonesSettings -Path (Join-Path $powerToysRoot 'FancyZones\settings.json')
    Set-TaskbarAutoHide
    Invoke-IfNotDryRun { Get-Process -Name WindowsVirtualDesktopHelper -ErrorAction SilentlyContinue | Stop-Process -Force }
    $linkInstaller = Join-Path $PSScriptRoot '..\..\setup\Install-Links.ps1'
    & $linkInstaller -SkipLinks -DesktopMode Native -DryRun:$DryRun
    if (-not $?) { throw 'Failed to configure Native startup shortcuts.' }

    if (Get-Command komorebic.exe -CommandType Application -ErrorAction SilentlyContinue) {
        Invoke-IfNotDryRun { komorebic stop 2>$null }
    }

    $komorebiAhk = Join-Path $HOME '.config\komorebi\komorebi.ahk'
    Invoke-IfNotDryRun { Stop-AutoHotkeyScript $komorebiAhk }

    $nativeScript = Join-Path $PSScriptRoot 'Native-Desktop.ahk'
    Invoke-IfNotDryRun { Start-Process -FilePath (Get-Command autohotkey.exe -CommandType Application).Source -ArgumentList ('"{0}"' -f $nativeScript) }

    Invoke-IfNotDryRun { Get-Process -Name yasb -ErrorAction SilentlyContinue | Stop-Process -Force }

    $powerToys = Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe'
    if (Test-Path -LiteralPath $powerToys) {
        Invoke-IfNotDryRun {
            Get-Process -Name PowerToys -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Process -FilePath $powerToys
        }
    }

    $message = if ($DryRun) { 'Native Windows desktop mode validated.' } else { 'Native Windows desktop mode is active.' }
    Write-Host $message -ForegroundColor Cyan
}
catch {
    Write-Error $_
    exit 1
}
