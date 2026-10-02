<#
Frees RAM on a long-running workstation. Prints the top memory users first, sorted
by private (committed) memory since a leaker grows there and trimming only hides it,
then empties every process's working set and, when elevated, runs Sysinternals
RAMMap to also empty the system working sets and the modified and standby lists so
the pages are really free. Windows pages trimmed memory back in on demand, so apps
may stutter briefly. Warns when commit charge is above 80% of the limit, which
means a leak and not just cache.

Usage:
  pwsh -File .\scripts\Optimize-Memory.ps1
  pwsh -File .\scripts\Optimize-Memory.ps1 -Stop msedgewebview2   # kill; host apps respawn it
  pwsh -File .\scripts\Optimize-Memory.ps1 -Restart Zotero        # kill and relaunch
  pwsh -File .\scripts\Optimize-Memory.ps1 -Explorer              # restart the shell
  pwsh -File .\scripts\Optimize-Memory.ps1 -Elevate               # rerun as admin (UAC prompt)
#>

[CmdletBinding()]
param(
    [string[]]$Stop,
    [string[]]$Restart,
    [switch]$Explorer,
    [switch]$Elevate
)

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\setup\Common.ps1')
if ($Elevate -and -not (Test-IsAdmin)) { return Invoke-ScriptElevated $PSCommandPath $PSBoundParameters }

Add-Type -Namespace Win -Name Mem -MemberDefinition @'
[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr process);
'@

function Get-Os { Get-CimInstance Win32_OperatingSystem }
function Get-FreeMb { [int]((Get-Os).FreePhysicalMemory / 1KB) }

# Stops every process of these names and waits for them to exit; returns their exe paths.
function Stop-Named([string[]]$names) {
    $procs = @(Get-Process $names -ErrorAction SilentlyContinue)
    $paths = $procs | Where-Object Path | ForEach-Object Path | Sort-Object -Unique
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    $procs | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    $paths
}

$before = Get-FreeMb

Write-Host 'Top memory users (processes of one name summed):'
Get-Process | Group-Object Name | ForEach-Object {
    [pscustomobject]@{
        Name      = $_.Name
        Count     = $_.Count
        PrivateMB = [int](($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB)
        WorkingMB = [int](($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    }
} | Sort-Object PrivateMB -Descending | Select-Object -First 8 | Format-Table -AutoSize | Out-String | Write-Host

if ($Stop) { $null = Stop-Named $Stop }
# One launch per exe, after the old instance is gone, so single-instance apps start.
if ($Restart) { Stop-Named $Restart | ForEach-Object { Start-Process $_ } }
if ($Explorer) { Stop-Process -Name explorer -Force }   # Windows relaunches the shell itself

$admin = Test-IsAdmin
if ($admin -and (Test-Command rammap)) {
    # -Ew covers the per-process trim below, including processes we cannot open
    foreach ($switch in '-Ew', '-Es', '-Em', '-Et', '-E0') {
        # working sets, system, modified, standby, priority-0 standby
        Start-Process rammap -ArgumentList '-accepteula', $switch -Wait -WindowStyle Hidden
    }
}
else {
    foreach ($p in Get-Process) {
        try { $null = [Win.Mem]::EmptyWorkingSet($p.Handle) } catch {}
    }
    Write-Warning ($admin ? 'rammap not found: install Sysinternals (scoop install sysinternals).'
        : 'Not elevated: skipped RAMMap (system working sets, modified and standby lists).')
}

$after = Get-FreeMb
"Free RAM: $before MB -> $after MB ($($after - $before) MB)"

$os = Get-Os
$commit = 100 * ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / $os.TotalVirtualMemorySize
if ($commit -gt 80) { Write-Warning ('Commit charge is {0:N0}% of the limit: something is leaking, see PrivateMB above.' -f $commit) }
