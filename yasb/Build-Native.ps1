<#
Builds a native helper, <name>.exe next to <name>.c, with gcc. Skips the build
when the exe is newer than the source, unless -Force. A running copy is
stopped for the build; a long-running -Windows helper is started again after.
Setup (Install-Startup.ps1) runs this for each helper.

Usage:
  pwsh -File .\yasb\Build-Native.ps1 .\yasb\battery\battery.c -Libs powrprof
  pwsh -File .\yasb\Build-Native.ps1 .\yasb\activitywatch\window-watcher.c -Libs winhttp -Windows -Force
#>

param(
    [Parameter(Mandatory)][string]$Source,
    [string[]]$Libs = @(),
    # GUI subsystem: no console window for a helper that runs in the background.
    [switch]$Windows,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Source = (Resolve-Path -LiteralPath $Source).Path
$exe = [IO.Path]::ChangeExtension($Source, '.exe')

if (-not $Force -and (Test-Path -LiteralPath $exe) -and (Get-Item -LiteralPath $exe).LastWriteTime -ge (Get-Item -LiteralPath $Source).LastWriteTime) {
    Write-Host "Up to date: $exe"
    return
}
if (-not (Get-Command gcc -ErrorAction SilentlyContinue)) {
    throw 'gcc not found; install it with: scoop install gcc'
}

$running = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exe)) -ErrorAction SilentlyContinue)
$running | Stop-Process -Force
$running | Wait-Process -ErrorAction SilentlyContinue

# Libraries go after the source, or the linker drops them unresolved.
$arguments = @('-O2', '-s', '-Wall') + @(if ($Windows) { '-mwindows' }) + @('-o', $exe, $Source) + @($Libs | ForEach-Object { "-l$_" })
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
throw "Building $exe failed."
