<#
Switch between the desktop shells. The laptop uses Native; an external monitor
uses Komorebi. Automatic monitor detection is intentionally not used.
#>

[CmdletBinding()]
param(
    [ValidateSet('Native', 'Komorebi')]
    [string]$DesktopMode = 'Native',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$shellScript = Join-Path $PSScriptRoot (Join-Path $DesktopMode 'Use-Desktop.ps1')
if (-not (Test-Path -LiteralPath $shellScript)) {
    throw "Desktop shell script not found: $shellScript"
}

& $shellScript -DryRun:$DryRun
exit $LASTEXITCODE
