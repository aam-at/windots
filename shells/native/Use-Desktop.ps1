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
    if ($settings[8] -eq 2) { return $false }

    $settings[8] = 2
    Invoke-IfNotDryRun { Set-ItemProperty -LiteralPath $path -Name Settings -Value $settings }
    return $true
}

# Windows 11 stores a Wallpaper override per virtual desktop; without one a
# desktop falls back to the global wallpaper, so every desktop shares it.
function Clear-DesktopWallpapers {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops\Desktops'
    $keys = @(Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_.GetValue('Wallpaper') })
    foreach ($key in $keys) {
        Invoke-IfNotDryRun { Remove-ItemProperty -LiteralPath $key.PSPath -Name Wallpaper }
    }
    return $keys.Count -gt 0
}

try {
    # Stop the Komorebi shell. Install-Startup launches komorebi.ahk from the
    # repo path, so match that rather than the ~/.config junction.
    if (Get-Command komorebic.exe -CommandType Application -ErrorAction SilentlyContinue) {
        Invoke-IfNotDryRun { komorebic stop 2>$null }
    }
    Invoke-IfNotDryRun { Stop-AutoHotkeyScript (Join-Path $PSScriptRoot '..\komorebi\komorebi.ahk') }

    & (Join-Path $PSScriptRoot '..\..\setup\Configure-PowerToys.ps1') -DryRun:$DryRun
    if (-not $?) { throw 'Failed to enable PowerToys utilities.' }
    Set-FancyZonesSettings -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\FancyZones\settings.json')
    $taskbarChanged = Set-TaskbarAutoHide
    $wallpapersCleared = Clear-DesktopWallpapers
    if ($taskbarChanged -or $wallpapersCleared) {
        # The YASB dock loses its window tracking when Explorer restarts;
        # stopping YASB lets Install-Startup relaunch it below.
        Invoke-IfNotDryRun {
            Stop-Process -Name explorer -Force
            Start-Process explorer.exe
            Get-Process -Name yasb -ErrorAction SilentlyContinue | Stop-Process -Force
        }
    }

    # Restart the helper so Install-Startup relaunches it with the linked config.
    Invoke-IfNotDryRun { Get-Process -Name WindowsVirtualDesktopHelper -ErrorAction SilentlyContinue | Stop-Process -Force }
    & (Join-Path $PSScriptRoot '..\..\setup\Install-Startup.ps1') -DesktopMode Native -DryRun:$DryRun
    if (-not $?) { throw 'Failed to configure Native startup shortcuts.' }

    # Install-Startup skips AutoHotkey when any AHK script is already running;
    # #SingleInstance Force makes this relaunch safe either way.
    $nativeScript = Join-Path $PSScriptRoot 'Native-Desktop.ahk'
    Invoke-IfNotDryRun { Start-Process -FilePath (Get-Command autohotkey.exe -CommandType Application).Source -ArgumentList ('"{0}"' -f $nativeScript) }

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
