<#
Run Doom's CLI with the isolated paths used by Emacs-Daemon.ps1 doom.
Always passes -! (--force) so a prompt Doom can't suppress doesn't hang
waiting for a keypress that can't reach Emacs through this shell chain.

Usage:
  .\Doom-Profile.ps1 [DOOM-ARG ...]
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$DoomArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fixes mojibake from Doom/Emacs writing UTF-8 (e.g. checkmarks) to a
# console still on the legacy code page. [Console]::OutputEncoding alone
# doesn't reliably reach the real Win32 console code page on every host
# (it only governs what .NET itself writes, not a native child process's
# direct console writes), so set it via chcp too.
$savedCodePage = [regex]::Match((chcp.com), '\d+').Value
$savedEncoding = [Console]::OutputEncoding
$null = chcp.com 65001
[Console]::OutputEncoding = [Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot '..\setup\Common.ps1')
$doom = Get-ProfilePaths 'doom'

if (-not (Test-Path -LiteralPath (Join-Path $doom.Framework 'bin'))) {
    throw "Doom is not installed at $($doom.Framework)"
}
if (-not (Test-Path -LiteralPath (Join-Path $doom.Profile 'init.el'))) {
    throw "Doom profile is not installed at $($doom.Profile)"
}

if ($DoomArgs -notcontains '-!' -and $DoomArgs -notcontains '--force') {
    # A prompt Doom can't suppress (e.g. straight.el asking to overwrite a
    # locally-modified package) hangs forever here: the confirmation reaches
    # Emacs through a pwsh -> bash -> emacs.exe chain that doesn't reliably
    # forward keystrokes. -! auto-accepts prompts instead of asking. It must
    # precede the subcommand: trailing args are forwarded (e.g. `doom emacs`
    # passes them to emacs.exe, which aborts startup on the unknown option).
    $DoomArgs = @('-!') + @($DoomArgs)
}

$doomCommand = @(
    # Doom's PowerShell wrapper currently references an unset exit variable
    # when Emacs returns a normal non-zero exit code. Prefer its shell launcher,
    # which preserves that exit code for Setup's error reporting.
    (Join-Path $doom.Framework 'bin\doom'),
    (Join-Path $doom.Framework 'bin\doom.cmd'),
    (Join-Path $doom.Framework 'bin\doom.ps1')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($doomCommand)) {
    throw "Doom CLI was not found under $($doom.Framework)\bin"
}

New-Item -ItemType Directory -Path $doom.Local -Force | Out-Null
try {
    Invoke-WithEnvironment $doom.Environment {
        if ([System.IO.Path]::GetExtension($doomCommand) -in @('.ps1', '.cmd')) {
            & $doomCommand @DoomArgs
        }
        else {
            # PATH's bash is often WSL's System32\bash.exe, which can't see Windows
            # paths; use the Git for Windows one (<git root>\bin, three levels above
            # git's exec path).
            $bash = Join-Path (git --exec-path) '..\..\..\bin\bash.exe'
            if (-not (Test-Path -LiteralPath $bash)) {
                throw "Doom CLI is a shell script; install Git for Windows or make doom.ps1 available at $($doom.Framework)\bin."
            }
            # bash eats backslashes in the path, so hand it forward slashes.
            & $bash ($doomCommand -replace '\\', '/') @DoomArgs
        }
    }
    $exitCode = $LASTEXITCODE
}
finally {
    # Leave the caller's console as it was.
    $null = chcp.com $savedCodePage
    [Console]::OutputEncoding = $savedEncoding
}

exit $exitCode
