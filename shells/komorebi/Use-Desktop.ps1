<#
Switch to the external-monitor desktop: Komorebi tiling with its AutoHotkey
bindings. Use shells\Use-Desktop.ps1 -DesktopMode Native on the laptop display instead.
#>

[CmdletBinding()]
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\setup\Common.ps1')

try {
    $linkInstaller = Join-Path $PSScriptRoot '..\..\setup\Install-Links.ps1'
    if (-not (Test-Path -LiteralPath $linkInstaller)) {
        throw "Link installer not found: $linkInstaller"
    }

    # Creates the Komorebi startup shortcuts and removes the native-mode one.
    & $linkInstaller -SkipLinks -DesktopMode Komorebi -DryRun:$DryRun
    if (-not $?) { throw 'Failed to configure Komorebi startup shortcuts.' }

    $nativeBindings = Join-Path $PSScriptRoot '..\native\Native-Desktop.ahk'
    Invoke-IfNotDryRun { Stop-AutoHotkeyScript $nativeBindings }
    Invoke-IfNotDryRun { Get-Process -Name WindowsVirtualDesktopHelper -ErrorAction SilentlyContinue | Stop-Process -Force }

    $config = Join-Path $PSScriptRoot 'komorebi.json'
    $bindings = Join-Path $PSScriptRoot 'komorebi.ahk'
    if (-not (Test-Path -LiteralPath $config)) { throw "Komorebi config not found: $config" }
    if (-not (Test-Path -LiteralPath $bindings)) { throw "Komorebi bindings not found: $bindings" }

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
