<#
Supervises one desktop app, restarting it after a nonzero exit. A clean exit is
left alone. Update-Apps.ps1 can pause a supervised app while Scoop replaces it.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppName,
    [Parameter(Mandatory)][string]$SpecBase64
)

$ErrorActionPreference = 'Stop'
$spec = [Text.Encoding]::Unicode.GetString(
    [Convert]::FromBase64String($SpecBase64)
) | ConvertFrom-Json
$pausePath = Join-Path $env:LOCALAPPDATA "windots\restart\$AppName.paused"
$restartDelay = 5
$mutex = [Threading.Mutex]::new($false, "Local\windots.Restart.$AppName")
if (-not $mutex.WaitOne(0)) { exit 0 }

function Wait-UntilUnpaused {
    while (Test-Path -LiteralPath $pausePath) {
        $ownerPid = 0
        $rawPid = Get-Content -LiteralPath $pausePath -Raw -ErrorAction SilentlyContinue
        if (-not [int]::TryParse($rawPid, [ref]$ownerPid)) {
            Remove-Item -LiteralPath $pausePath -Force -ErrorAction SilentlyContinue
            continue
        }
        if (-not (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $pausePath -Force -ErrorAction SilentlyContinue
            continue
        }
        Start-Sleep -Seconds 2
    }
}

function Find-ExistingAppProcess {
    $scriptMatch = if ($spec.ScriptPath) {
        [IO.Path]::GetFullPath([string]$spec.ScriptPath)
    }
    $executableMatch = if (-not $scriptMatch) {
        [IO.Path]::GetFullPath([string]$spec.Executable)
    }
    foreach ($process in Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) {
        if ($process.Name -notin @($spec.ProcessNames)) { continue }
        if ($scriptMatch -and $process.CommandLine -notlike "*$scriptMatch*") {
            continue
        }
        if (
            $executableMatch -and
            $process.ExecutablePath -ne $executableMatch
        ) { continue }
        try { return Get-Process -Id $process.ProcessId -ErrorAction Stop }
        catch { continue }
    }
}

$process = $null

while ($true) {
    Wait-UntilUnpaused
    if (-not $process) { $process = Find-ExistingAppProcess }
    if (-not $process) {
        $start = @{
            FilePath = [string]$spec.Executable
            ErrorAction = 'Stop'
        }
        if ($spec.Arguments) { $start.ArgumentList = [string]$spec.Arguments }
        $launcher = Start-Process @start -PassThru
        for ($attempt = 0; $attempt -lt 100; $attempt++) {
            $process = Find-ExistingAppProcess
            if ($process) { break }
            if ($launcher.HasExited -and $launcher.ExitCode -eq 0) { exit 0 }
            Start-Sleep -Milliseconds 100
        }
        if (-not $process) {
            if (-not $launcher.HasExited) { $process = $launcher }
            else { $process = $null; continue }
        }
    }

    $startedAt = Get-Date
    try { $process.WaitForExit() }
    catch { $process = $null; continue }
    $exitCode = $process.ExitCode
    $process = $null
    if ($exitCode -eq 0) { exit 0 }
    if (((Get-Date) - $startedAt).TotalSeconds -ge 60) { $restartDelay = 5 }
    Start-Sleep -Seconds $restartDelay
    $restartDelay = [Math]::Min(300, $restartDelay * 2)
}
