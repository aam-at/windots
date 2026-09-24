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
$null = chcp.com 65001
[Console]::OutputEncoding = [Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot '..\setup\Common.ps1')
$roots = Get-EmacsRoots
$configRoot = $roots.ConfigRoot
$dataRoot = $roots.DataRoot
$stateRoot = $roots.StateRoot

$framework = Join-Path $dataRoot 'doom'
$profileDirectory = Join-Path $configRoot 'doom'
$localDirectory = Join-Path $stateRoot 'doom'

if (-not (Test-Path -LiteralPath (Join-Path $framework 'bin'))) {
    throw "Doom is not installed at $framework"
}
if (-not (Test-Path -LiteralPath (Join-Path $profileDirectory 'init.el'))) {
    throw "Doom profile is not installed at $profileDirectory"
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
    (Join-Path $framework 'bin\doom'),
    (Join-Path $framework 'bin\doom.cmd'),
    (Join-Path $framework 'bin\doom.ps1')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($doomCommand)) {
    throw "Doom CLI was not found under $framework\bin"
}

New-Item -ItemType Directory -Path $localDirectory -Force | Out-Null
$savedEnvironment = @{
    EMACSDIR     = [Environment]::GetEnvironmentVariable('EMACSDIR', 'Process')
    DOOMDIR      = [Environment]::GetEnvironmentVariable('DOOMDIR', 'Process')
    DOOMLOCALDIR = [Environment]::GetEnvironmentVariable('DOOMLOCALDIR', 'Process')
}

try {
    $env:EMACSDIR = $framework
    $env:DOOMDIR = $profileDirectory
    $env:DOOMLOCALDIR = $localDirectory

    if ([System.IO.Path]::GetExtension($doomCommand) -in @('.ps1', '.cmd')) {
        & $doomCommand @DoomArgs
    }
    else {
        $bash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $bash) { $bash = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if ($null -eq $bash) {
            throw "Doom CLI is a shell script; install Git Bash or make doom.ps1 available at $framework\bin."
        }
        & $bash.Source $doomCommand @DoomArgs
    }
    $exitCode = $LASTEXITCODE
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item -Path "Env:$name" -Value $savedEnvironment[$name] }
    }
}

exit $exitCode
