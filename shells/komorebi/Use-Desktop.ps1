<#
Switch to the external-monitor desktop: Komorebi tiling with its AutoHotkey
bindings. Use shells\native\Use-Desktop.ps1 on the laptop display instead.
#>

[CmdletBinding()]
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\setup\Common.ps1')

try {
    # Creates the Komorebi startup shortcuts and removes the native-mode one.
    & (Join-Path $PSScriptRoot '..\..\setup\Install-Startup.ps1') -DesktopMode Komorebi -DryRun:$DryRun
    if (-not $?) { throw 'Failed to configure Komorebi startup shortcuts.' }

    # FancyZones off: two window managers would fight over every window.
    & (Join-Path $PSScriptRoot '..\..\setup\Configure-PowerToys.ps1') -DesktopMode Komorebi -DryRun:$DryRun
    if (-not $?) { throw 'Failed to configure PowerToys.' }

    $nativeBindings = Join-Path $PSScriptRoot '..\native\Native-Desktop.ahk'
    Invoke-IfNotDryRun { Stop-AutoHotkeyScript $nativeBindings }
    Invoke-IfNotDryRun { Get-Process -Name WindowsVirtualDesktopHelper -ErrorAction SilentlyContinue | Stop-Process -Force }

    $config = Join-Path $PSScriptRoot 'komorebi.json'
    $bindings = Join-Path $PSScriptRoot 'komorebi.ahk'

    if (-not (Get-Command komorebic.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'komorebic.exe was not found on PATH.'
    }
    if (-not (Get-Command autohotkey.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'autohotkey.exe was not found on PATH.'
    }

    Invoke-IfNotDryRun { komorebic stop 2>$null }
    Invoke-IfNotDryRun {
        komorebic start --clean-state --config $config
        if ($LASTEXITCODE -ne 0) { throw "Komorebi failed to start with exit code $LASTEXITCODE." }
    }
    Invoke-IfNotDryRun {
        Start-Process -FilePath (Get-Command autohotkey.exe -CommandType Application).Source -ArgumentList ('"{0}"' -f $bindings)
    }

    # PowerToys reads its settings only at startup.
    $powerToys = Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe'
    if (Test-Path -LiteralPath $powerToys) {
        Invoke-IfNotDryRun {
            Get-Process -Name PowerToys -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Process -FilePath $powerToys
        }
    }

    $yasb = Get-Command yasb.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($yasb) {
        Invoke-IfNotDryRun {
            Get-Process -Name yasb -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Process -FilePath $yasb.Source -WindowStyle Hidden
        }
    }

    $message = if ($DryRun) { 'Komorebi desktop mode validated.' } else { 'Komorebi desktop mode is active.' }
    Write-Host $message -ForegroundColor Cyan
}
catch {
    Write-Error $_
    exit 1
}
