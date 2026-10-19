<#
Updates the apps the setup scripts installed, without rerunning them: winget,
Scoop (and the manifests in scoop\), Bun globals, uv tools and PowerShell
modules. Package lists come from setup\Packages.ps1. Pinned installs (the
VirtualDesktopAccessor.dll, the fswatch and ledger builds, Codex and OMP) are
not updated. The manifest bump writes to scoop\; review it with git diff.
A running app is stopped only when Scoop has an update for it and can't install
it while it runs, and it is restarted right after its update. Chrome closes
without asking and reopens with its last session. You're asked first for the
others (AutoHotkey, YASB and ActivityWatch come back from their Startup shortcuts).
To update Scoop's pwsh itself, close PowerShell 7 sessions and open Update-Apps.cmd
from Explorer. It uses the built-in Windows PowerShell, avoiding a lock on pwsh.

Usage:
  .\scripts\Update-Apps.cmd                         # includes pwsh (close it first)
  pwsh -File .\scripts\Update-Apps.ps1                # everything
  pwsh -File .\scripts\Update-Apps.ps1 -SkipBump      # keep scoop\ manifests as is
  pwsh -File .\scripts\Update-Apps.ps1 -SkipScoop -SkipWinget
  pwsh -File .\scripts\Update-Apps.ps1 -DryRun        # print steps, run nothing
#>

[CmdletBinding()]
param(
    [switch]$SkipBump,
    [switch]$SkipScoop,
    [switch]$SkipWinget,
    [switch]$SkipBun,
    [switch]$SkipUv,
    [switch]$SkipModules,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\setup\Common.ps1')
. (Join-Path $PSScriptRoot '..\setup\Packages.ps1')

$failures = [System.Collections.Generic.List[string]]::new()

# Runs one update. A failure is recorded and the run carries on.
function Invoke-Update {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action,
        [int[]]$SuccessExitCodes = @(0)
    )
    if (-not (Invoke-NativeCommand -Description $Description -Action $Action `
                -SuccessExitCodes $SuccessExitCodes)) {
        $failures.Add($Description)
    }
}

# git's fsmonitor daemons hold git.exe open, which blocks git's own Scoop update.
# They respawn on the next git call, so stopping them is safe.
function Stop-GitMonitors {
    $daemons = @(Get-CimInstance Win32_Process -Filter "Name='git.exe'" |
            Where-Object CommandLine -Match 'fsmonitor--daemon')
    if (-not $daemons) { return }
    Write-Info 'Stopping git fsmonitor daemons (they restart on demand)'
    Invoke-IfNotDryRun {
        $daemons | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

# Scoop manifests first, so the Scoop update below picks up their new versions.
$manifestDir = WindotsPath 'scoop'
$checkver = Join-Path (scoop prefix scoop) 'bin\checkver.ps1'
if ($SkipBump) {
    Write-Info 'Skipping the scoop\ manifest bump'
}
elseif (Test-Path -LiteralPath $checkver) {
    Write-Info 'Bumping scoop\ manifests to the latest releases'
    Invoke-IfNotDryRun {
        # Scoop's scripts read absent config keys, which our strict mode rejects.
        & {
            Set-StrictMode -Off
            & $checkver -App '*' -Dir $manifestDir -Update -SkipUpdated
        }
    }
}

if ($SkipScoop) {
    Write-Info 'Skipping Scoop'
}
elseif (Test-Command 'scoop') {
    Stop-GitMonitors
    Write-Info 'Updating Scoop, its buckets and every installed Scoop app'
    Invoke-Update 'scoop update' { scoop update }
    $script:blocked = @()
    Invoke-IfNotDryRun {
        # Scoop reports a blocked app with Write-Host, which only *>&1 captures.
        $output = scoop update '*' *>&1
        $output | Out-Host
        # Scoop skips an app that is still running; name them so they can close.
        $script:blocked = @(
            [regex]::Matches(($output | Out-String),
                'instances of "([^"]+)" are still running') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        )
    }
    foreach ($app in $script:blocked) {
        if (-not (Stop-ForUpdate $app)) {
            $failures.Add("still running: $app")
            continue
        }
        try {
            Invoke-Update "scoop update $app" { scoop update $app }
        }
        finally {
            # Also on Ctrl+C, so a stopped app doesn't stay down.
            Restart-ScoopLiveApp $app
        }
    }
}
else {
    Write-Warn 'scoop not found; skipping Scoop apps.'
}

if ($SkipWinget) {
    Write-Info 'Skipping winget'
}
elseif (Test-Command 'winget') {
    Write-Info 'Updating winget packages'
    foreach ($id in $wingetApps) {
        # Installers run silently and can take minutes; say which one is running.
        Write-Info "winget upgrade $id (installers can take minutes)"
        # -1978335189: no newer version. -1978335212: not installed, so nothing
        # to update (upgrade never installs).
        Invoke-Update -Description "winget upgrade $id" -SuccessExitCodes @(
            0, -1978335189, -1978335212
        ) -Action {
            winget upgrade -e --id $id --silent --accept-source-agreements `
                --accept-package-agreements
        }
    }
}
else {
    Write-Warn 'winget not found; skipping winget packages.'
}

if ($SkipBun) {
    Write-Info 'Skipping Bun'
}
elseif (Test-Command 'bun') {
    Write-Info 'Updating Bun globals'
    foreach ($app in $bunApps + $aiBunTools) {
        # Installs the latest version, which is how setup updates these too. Its
        # output is shown as it runs, one package at a time.
        Write-Info "bun add --global $app"
        Invoke-Update "bun $app" { bun add --global $app 2>&1 | Out-Host }
    }
}
else {
    Write-Warn 'bun not found; skipping Bun packages.'
}

if ($SkipUv) {
    Write-Info 'Skipping uv'
}
elseif (Test-Command 'uv') {
    Write-Info 'Updating uv tools'
    foreach ($tool in $uvTools + $aiUvTools) {
        Invoke-Update "uv tool $tool" { uv tool upgrade $tool }
    }
}
else {
    Write-Warn 'uv not found; skipping uv tools.'
}

if ($SkipModules) {
    Write-Info 'Skipping PowerShell modules'
}
else {
    Write-Info 'Updating PowerShell modules'
    foreach ($module in $psModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) { continue }
        Invoke-IfNotDryRun {
            try {
                Update-Module -Name $module -Force -ErrorAction Stop
            }
            catch {
                Write-Warn "Update-Module $module failed: $_"
                $failures.Add("module:$module")
            }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Warn "Some updates failed: $($failures -join ', ')"
    exit 1
}
Write-Info 'Done. Review the manifest changes with: git diff scoop'
