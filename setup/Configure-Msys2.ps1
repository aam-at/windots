<#
Configures Scoop's MSYS2 after install: updates it, installs Emacs (native
compilation, -O2) plus gcc, pkgconf, enchant and the English hunspell dictionary for
jinx, and shims Emacs over Scoop's. Puts UCRT64 on the user PATH so Emacs finds cc and
libenchant-2.dll, and on PKG_CONFIG_PATH because Scoop's pkg-config shim comes first
on PATH and can't see MSYS2's enchant-2.pc.

Usage:
  pwsh -NoProfile -File .\setup\Configure-Msys2.ps1 [-DryRun]
#>

[CmdletBinding()]
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$root = Join-Path $ScoopRoot 'apps\msys2\current'
$bash = Join-Path $root 'usr\bin\bash.exe'
if (-not (Test-Path -LiteralPath $bash)) { throw 'run: scoop install msys2' }

$packages = 'emacs', 'enchant', 'gcc', 'hunspell-en', 'pkgconf' |
    ForEach-Object { "mingw-w64-ucrt-x86_64-$_" }

Write-Info 'Updating MSYS2 and installing Emacs with the jinx toolchain'
Invoke-IfNotDryRun {
    $env:MSYSTEM = 'UCRT64'; $env:CHERE_INVOKING = '1'
    # A core update (msys2-runtime) kills the shell and exits non-zero, so run
    # -Syu twice and ignore both codes; the install below is the real check.
    1..2 | ForEach-Object { & $bash -lc 'pacman -Syu --noconfirm' }
    & $bash -lc "pacman -S --needed --noconfirm $packages"
    if ($LASTEXITCODE -ne 0) { throw "MSYS2 pacman failed (exit $LASTEXITCODE)" }
}

$ucrt = Join-Path $root 'ucrt64'
$user = [Environment]::GetEnvironmentVariable('Path', 'User')
$pc = "$ucrt\lib\pkgconfig;$ucrt\share\pkgconfig"
Invoke-IfNotDryRun {
    if (@($user -split ';') -notcontains "$ucrt\bin") {
        [Environment]::SetEnvironmentVariable('Path', "$user;$ucrt\bin", 'User')
    }
    [Environment]::SetEnvironmentVariable('PKG_CONFIG_PATH', $pc, 'User')
}

foreach ($name in 'emacs', 'emacsclient', 'emacsclientw', 'runemacs') {
    Write-Info "Shimming $name from MSYS2"
    Invoke-IfNotDryRun {
        if (Test-Path -LiteralPath "$ScoopRoot\shims\$name.exe") { scoop shim rm $name }
        scoop shim add $name "$ucrt\bin\$name.exe"
        if ($LASTEXITCODE -ne 0) { throw "scoop shim add $name failed" }
    }
}
