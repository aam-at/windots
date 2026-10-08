<#
Builds fswatch from source in MSYS2 (UCRT64 toolchain, per its README.windows)
and shims it into Scoop. No Windows binaries or Scoop package exist upstream.

Usage:
  pwsh -File .\setup\Install-Fswatch.ps1
  pwsh -File .\setup\Install-Fswatch.ps1 -Version 1.22.0 -Force

Needs Scoop's msys2 (setup\Install-Apps.ps1 installs it).
#>

[CmdletBinding()]
param(
    [string]$Version = '1.22.0',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
$bash = Join-Path $ScoopRoot 'apps\msys2\current\usr\bin\bash.exe'
if (-not (Test-Path -LiteralPath $bash)) {
    throw 'msys2 not found; run: scoop install msys2'
}

$prefix = Join-Path $env:LOCALAPPDATA 'fswatch'
$exe = Join-Path $prefix 'bin\fswatch.exe'
if (-not $Force -and (Test-Path -LiteralPath $exe) -and
    ((& $exe --version | Select-Object -First 1) -match [regex]::Escape($Version))) {
    Write-Host "fswatch $Version already installed: $exe"
}
else {
    # Static link and no NLS (libintl-8.dll), so the shimmed exe needs no MSYS2 DLLs
    # on PATH.
    $script = @'
set -euo pipefail
pacman -S --needed --noconfirm mingw-w64-ucrt-x86_64-{gcc,cmake,ninja} tar
src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
cd "$src"
url="https://github.com/emcrisostomo/fswatch/archive/refs/tags/$FSW_VERSION.tar.gz"
curl -fsSL "$url" | tar xz --exclude=README --exclude=README.illumos
cd "fswatch-$FSW_VERSION"
# Upstream still calls POSIX sigaction, which MinGW lacks (fswatch issue 214);
# MSYS2's own package skips signal handlers on Windows the same way.
sed -i '/^static void register_signal_handlers()/,/^}/{/^{/a #ifndef _WIN32
/^}/i #endif
}' fswatch/src/fswatch.cpp
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$(cygpath -u "$FSW_PREFIX")" \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_EXE_LINKER_FLAGS=-static -DUSE_NLS=OFF
cmake --build build --target fswatch
install -D build/fswatch/src/fswatch.exe "$(cygpath -u "$FSW_PREFIX")/bin/fswatch.exe"
'@ -replace "`r`n", "`n"
    $env:MSYSTEM = 'UCRT64'; $env:CHERE_INVOKING = '1'
    $env:FSW_VERSION = $Version; $env:FSW_PREFIX = $prefix
    & $bash -lc $script
    if ($LASTEXITCODE -ne 0) { throw "fswatch build failed (exit $LASTEXITCODE)" }
}

scoop shim add fswatch $exe
if ($LASTEXITCODE -ne 0) { throw 'scoop shim add fswatch failed' }
