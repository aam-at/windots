<#
Run Doom's CLI with the isolated paths used by emacs-daemon.ps1 doom.

Usage:
  .\doom-profile.ps1 [DOOM-ARG ...]
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$DoomArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) { Join-Path $HOME '.config\emacs' } else { Join-Path $env:XDG_CONFIG_HOME 'emacs' }
$dataRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_DATA_HOME)) { Join-Path $HOME '.local\share\emacs' } else { Join-Path $env:XDG_DATA_HOME 'emacs' }
$stateRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_STATE_HOME)) { Join-Path $HOME '.local\state\emacs' } else { Join-Path $env:XDG_STATE_HOME 'emacs' }

$framework = Join-Path $dataRoot 'doom'
$profileDirectory = Join-Path $configRoot 'doom'
$localDirectory = Join-Path $stateRoot 'doom'

if (-not (Test-Path -LiteralPath (Join-Path $framework 'init.el'))) {
    throw "Doom is not installed at $framework"
}
if (-not (Test-Path -LiteralPath (Join-Path $profileDirectory 'init.el'))) {
    throw "Doom profile is not installed at $profileDirectory"
}

$doomCommand = @(
    (Join-Path $framework 'bin\doom.ps1'),
    (Join-Path $framework 'bin\doom.cmd'),
    (Join-Path $framework 'bin\doom')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($doomCommand)) {
    throw "Doom CLI was not found under $framework\bin"
}

New-Item -ItemType Directory -Path $localDirectory -Force | Out-Null
$savedEnvironment = @{
    EMACSDIR = [Environment]::GetEnvironmentVariable('EMACSDIR', 'Process')
    DOOMDIR = [Environment]::GetEnvironmentVariable('DOOMDIR', 'Process')
    DOOMLOCALDIR = [Environment]::GetEnvironmentVariable('DOOMLOCALDIR', 'Process')
}

try {
    $env:EMACSDIR = $framework
    $env:DOOMDIR = $profileDirectory
    $env:DOOMLOCALDIR = $localDirectory

    if ([System.IO.Path]::GetExtension($doomCommand) -in @('.ps1', '.cmd')) {
        & $doomCommand @DoomArgs
    } else {
        $bash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue
        if ($null -eq $bash) { $bash = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue }
        if ($null -eq $bash) {
            throw "Doom CLI is a shell script; install Git Bash or make doom.ps1 available at $framework\bin."
        }
        & $bash.Source $doomCommand @DoomArgs
    }
    $exitCode = $LASTEXITCODE
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item -Path "Env:$name" -Value $savedEnvironment[$name] }
    }
}

exit $exitCode
