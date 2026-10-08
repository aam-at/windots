<#
Formats PowerShell files via PSScriptAnalyzer. Used by the pre-commit hook.

Usage:
  pwsh -File .\scripts\Format-PowerShell.ps1 <path> [<path> ...]
#>

param(
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer

$settings = Join-Path $PSScriptRoot '..\PSScriptAnalyzerSettings.psd1'
$maxLine = 88
$rule = @{ Enable = $true; MaximumLineLength = $maxLine }
$longLines = @{ Rules = @{ PSAvoidLongLines = $rule } }
$failures = 0

foreach ($file in $Path) {
    $source = Get-Content -LiteralPath $file -Raw
    $formatted = Invoke-Formatter -ScriptDefinition $source -Settings $settings
    if ($formatted -ne $source) {
        $utf8 = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Resolve-Path -LiteralPath $file), $formatted, $utf8)
    }
    # The formatter can't wrap lines, so long ones fail the hook for a manual fix.
    $found = Invoke-ScriptAnalyzer -Path $file -Settings $longLines `
        -IncludeRule PSAvoidLongLines
    foreach ($f in $found) {
        $msg = "${file}:$($f.Line): longer than $maxLine characters"
        Write-Host $msg -ForegroundColor Red
        $failures++
    }
}
if ($failures) { exit 1 }
