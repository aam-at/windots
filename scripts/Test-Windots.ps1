<#
Load-time checks for the repo's scripts. Used by the pre-commit hook.
  - PowerShell files must parse.
  - AutoHotkey files must pass AutoHotkey's own /Validate (syntax, bad
    hotkeys) without running them, with #Warn on so typos such as an unknown
    function name (which v2 treats as an unset variable) fail too.
  - C files (native helpers) must compile without warnings, and their
    <name>.test.c unit tests must pass.

Usage:
  pwsh -File .\scripts\Test-Windots.ps1              # every tracked .ps1/.ahk/.c
  pwsh -File .\scripts\Test-Windots.ps1 <path> ...   # just these files
#>

param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Path) { $Path = git -C $repoRoot ls-files '*.ps1' '*.ahk' '*.c' | ForEach-Object { Join-Path $repoRoot $_ } }

$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $HOME 'scoop' }
$autoHotkey = Join-Path $scoopRoot 'apps\autohotkey\current\v2\AutoHotkey64.exe'
$failures = 0
$checkedC = @()
$warnAll = New-TemporaryFile
Set-Content -LiteralPath $warnAll -Value '#Warn All, StdOut'

foreach ($file in $Path) {
    switch ([IO.Path]::GetExtension($file)) {
        '.ps1' {
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $file), [ref]$null, [ref]$errors)
            foreach ($e in $errors) { Write-Host "${file}:$($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red; $failures++ }
        }
        '.c' {
            # Native helpers: compile with warnings as errors, and run the
            # <name>.test.c next to the source (which includes it) if any.
            $source = $file -replace '\.test\.c$', '.c'
            $test = $source -replace '\.c$', '.test.c'
            if ($source -in $checkedC) { continue }
            $checkedC += $source
            if (-not (Get-Command gcc -ErrorAction SilentlyContinue)) {
                Write-Warning "gcc not found; skipping $file"
                continue
            }
            $exe = Join-Path ([IO.Path]::GetTempPath()) "windots-test-$([IO.Path]::GetFileNameWithoutExtension($source)).exe"
            $build = if (Test-Path -LiteralPath $test) { $test } else { $source }
            $output = gcc -Wall -Werror -o $exe $build -lwinhttp -lpowrprof 2>&1
            if ($LASTEXITCODE -ne 0) { $output | Write-Host -ForegroundColor Red; $failures++; continue }
            if ($build -eq $test) {
                $output = & $exe 2>&1
                if ($LASTEXITCODE -ne 0) { $output | Write-Host -ForegroundColor Red; $failures++ }
            }
            Remove-Item -LiteralPath $exe -ErrorAction SilentlyContinue
        }
        '.ahk' {
            if (-not (Test-Path -LiteralPath $autoHotkey)) {
                Write-Warning "AutoHotkey v2 not found at $autoHotkey; skipping $file"
                continue
            }
            $errors, $warnings = (New-TemporaryFile), (New-TemporaryFile)
            $arguments = '/ErrorStdOut=UTF-8', '/Validate', '/include', "`"$warnAll`"", "`"$(Resolve-Path -LiteralPath $file)`""
            $process = Start-Process $autoHotkey -ArgumentList $arguments -Wait -PassThru -NoNewWindow -RedirectStandardError $errors -RedirectStandardOutput $warnings
            $output = @(Get-Content -LiteralPath $errors, $warnings)
            if ($process.ExitCode -ne 0 -or $output) { $output | Write-Host -ForegroundColor Red; $failures++ }
            Remove-Item -LiteralPath $errors, $warnings
        }
    }
}

Remove-Item -LiteralPath $warnAll
if ($failures) { throw "$failures problem(s) found." }
Write-Host "Checked $(@($Path).Count) file(s)."
