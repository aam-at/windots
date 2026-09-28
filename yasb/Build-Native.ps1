<#
Builds a native helper, <name>.exe next to <name>.c, with gcc. The C library
shared with dotfiles' tools (dotfiles\tools\lib: http.h, json.h) is on the
include path. Skips the build when the exe is newer than every .c and .h
beside the source and in the shared library, unless -Force.
A running copy is stopped for the build; a long-running -Windows helper is
started again after. Setup (Install-Startup.ps1) runs this for each helper.

Usage:
  pwsh -File .\yasb\Build-Native.ps1 .\yasb\battery\battery.c -Libs powrprof
  pwsh -File .\yasb\Build-Native.ps1 .\yasb\activitywatch\window-watcher.c -Libs ws2_32 -Windows
  pwsh -File .\yasb\Build-Native.ps1 $env:DOTFILES\tools\wellbeing\wellbeing.c -Libs ws2_32,dwmapi -Windows -Force
#>

param(
    [Parameter(Mandatory)][string]$Source,
    [string[]]$Libs = @(),
    # GUI subsystem: no console window for a helper that runs in the background.
    [switch]$Windows,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
# pwsh -File passes "ws2_32,dwmapi" as one string.
$Libs = @($Libs -split ',' | ForEach-Object Trim | Where-Object { $_ })
$Source = (Resolve-Path -LiteralPath $Source).Path
$exe = [IO.Path]::ChangeExtension($Source, '.exe')
$dotfiles = if ($env:DOTFILES) { $env:DOTFILES } else { Join-Path $HOME 'dotfiles' }
$library = Join-Path $dotfiles 'tools\lib'

# Any C file beside the source or in the library, included or not: a
# needless rebuild is cheap.
$inputs = Get-ChildItem -Path "$(Split-Path -Parent $Source)\*", "$library\*" -Include *.c, *.h -File -ErrorAction SilentlyContinue
$newest = ($inputs | Measure-Object -Property LastWriteTime -Maximum).Maximum
if (-not $Force -and (Test-Path -LiteralPath $exe) -and (Get-Item -LiteralPath $exe).LastWriteTime -ge $newest) {
    Write-Host "Up to date: $exe"
    return
}
if (-not (Get-Command gcc -ErrorAction SilentlyContinue)) {
    throw 'gcc not found; install it with: scoop install gcc'
}

# This exe running as the helper: not a same-named exe elsewhere, and not a
# short-lived command such as YASB's `wellbeing.exe --status`.
$name = [IO.Path]::GetFileName($exe)
$running = @(Get-CimInstance Win32_Process -Filter "Name = '$name'" | Where-Object {
        $_.ExecutablePath -eq $exe -and $_.CommandLine -notmatch '\s--?\w'
    } | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
$running | Stop-Process -Force
$running | Wait-Process -ErrorAction SilentlyContinue

# Libraries go after the source, or the linker drops them unresolved.
$arguments = @('-O2', '-s', '-Wall') + @(if ($Windows) { '-mwindows' }) + @('-I', $library, '-o', $exe, $Source) + @($Libs | ForEach-Object { "-l$_" })
# YASB starts battery.exe every second and holds it for a moment; retry past that.
foreach ($attempt in 1..5) {
    $output = gcc @arguments 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Built $exe"
        if ($running -and $Windows) { Start-Process -FilePath $exe }
        return
    }
    Start-Sleep -Milliseconds 300
}
$output | Out-Host
# A failed link leaves the previous exe; keep it running rather than nothing.
if ($running -and $Windows -and (Test-Path -LiteralPath $exe)) { Start-Process -FilePath $exe }
throw "Building $exe failed."
