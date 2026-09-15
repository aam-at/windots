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

foreach ($file in $Path) {
    $source = Get-Content -LiteralPath $file -Raw
    $formatted = Invoke-Formatter -ScriptDefinition $source
    if ($formatted -ne $source) {
        [IO.File]::WriteAllText((Resolve-Path -LiteralPath $file), $formatted, [Text.UTF8Encoding]::new($false))
    }
}
