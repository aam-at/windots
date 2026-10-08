<#
General tune-up for a long-running workstation: retrims the SSD (elevated), flushes
the DNS cache, lists what starts at logon (enabled entries only; it disables
nothing), reports disk health (wear and errors need elevation) and the last week's
crashes, and warns when a restart is pending or uptime is high, since a reboot
clears kernel pool and driver leaks that no script can. -RebuildCaches also resets
the icon cache and, elevated, the font caches (restarts Explorer).

Usage:
  pwsh -File .\scripts\Optimize-System.ps1
  pwsh -File .\scripts\Optimize-System.ps1 -RebuildCaches
  pwsh -File .\scripts\Optimize-System.ps1 -WhatIf
  pwsh -File .\scripts\Optimize-System.ps1 -Elevate     # rerun as admin (UAC prompt)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$RebuildCaches,
    [int]$MaxUptimeDays = 7,
    [switch]$Elevate
)

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\setup\Common.ps1')
if ($Elevate -and -not (Test-IsAdmin)) {
    return Invoke-ScriptElevated $PSCommandPath $PSBoundParameters
}

$admin = Test-IsAdmin

if (-not $admin) { Write-Warning 'Not elevated: skipped the SSD retrim.' }
elseif ($PSCmdlet.ShouldProcess($env:SystemDrive, 'ReTrim')) {
    Optimize-Volume -DriveLetter $env:SystemDrive[0] -ReTrim
}

if ($PSCmdlet.ShouldProcess('DNS cache', 'Flush')) { Clear-DnsClientCache }

if ($RebuildCaches -and $PSCmdlet.ShouldProcess('icon and font caches', 'Rebuild')) {
    if ($admin) { Stop-Service FontCache -Force -ErrorAction SilentlyContinue }
    else {
        Write-Warning ('Not elevated: rebuilding the icon cache only, ' +
            'not the font caches.')
    }
    # ponytail: Windows relaunches Explorer within a second or so, which can re-lock a
    # cache file before it is removed; set AutoRestartShell=0 around this if that bites.
    $shell = Get-Process explorer -ErrorAction SilentlyContinue
    $shell | Stop-Process -Force -ErrorAction SilentlyContinue
    $shell | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
    Remove-Item -Force -ErrorAction SilentlyContinue -Path @(
        "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db"
        "$env:LOCALAPPDATA\IconCache.db"
    )
    if ($admin) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -Path @(
            "$env:SystemRoot\ServiceProfiles\LocalService\AppData\Local\FontCache\*"
            "$env:SystemRoot\System32\FNTCACHE.DAT"
        )
        Start-Service FontCache -ErrorAction SilentlyContinue
    }
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer
    }
}

# Task Manager's on/off switch: StartupApproved values whose first byte is odd are
# disabled.
$approved = 'Run', 'Run32', 'StartupFolder' | ForEach-Object {
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$_"
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$_"
} | Get-Item -ErrorAction SilentlyContinue
$disabled = foreach ($key in $approved) {
    $key.GetValueNames() | Where-Object {
        ($v = $key.GetValue($_)) -is [byte[]] -and $v[0] % 2
    }
}

Write-Host 'Startup commands (enabled):'
Get-CimInstance Win32_StartupCommand | Where-Object {
    $_.Location -notmatch 'S-1-5-18|\.DEFAULT' -and # system accounts never log on
    $_.Name -notin $disabled -and
    $_.Command -notin $disabled   # StartupFolder keys by .lnk name
} | Select-Object Name, Command, Location | Format-Table -AutoSize -Wrap |
Out-String | Write-Host

Write-Host 'Logon scheduled tasks (enabled, non-Microsoft):'
Get-ScheduledTask | Where-Object {
    $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' -and
    @($_.Triggers | Where-Object {
            $_ -and $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger'
        }).Count
} | Select-Object TaskName, TaskPath, State | Format-Table -AutoSize |
Out-String | Write-Host

# The rest only reads, and the Storage module chatters under -WhatIf.
$WhatIfPreference = $false
Write-Host 'Disks:'
$disks = Get-PhysicalDisk | ForEach-Object {
    $r = if ($admin) {
        $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{
        Disk = $_.FriendlyName
        Health = $_.HealthStatus
        'Wear%' = ${r}?.Wear
        TempC = ${r}?.Temperature
        ReadErrors = ${r}?.ReadErrorsUncorrected
        Hours = ${r}?.PowerOnHours
    }
}
$disks | Format-Table -AutoSize | Out-String | Write-Host
foreach ($d in $disks | Where-Object {
        $_.Health -ne 'Healthy' -or $_.'Wear%' -gt 80 -or $_.ReadErrors -gt 0
    }) {
    Write-Warning "$($d.Disk) is failing or worn out: back it up."
}

$since = (Get-Date).AddDays(-7)
$system = @(Get-WinEvent -ErrorAction SilentlyContinue -FilterHashtable @{
        LogName = 'System'; StartTime = $since; Id = 41, 1001
        ProviderName = 'Microsoft-Windows-Kernel-Power',
        'Microsoft-Windows-WER-SystemErrorReporting'
    })
$bugchecks = @($system | Where-Object Id -EQ 1001).Count
'Last 7 days: {0} blue screens, {1} unexpected shutdowns' -f
$bugchecks, ($system.Count - $bugchecks)
Write-Host 'Apps that crashed or hung in the last 7 days:'
Get-WinEvent -ErrorAction SilentlyContinue -FilterHashtable @{
    LogName = 'Application'; StartTime = $since; Id = 1000, 1002
    ProviderName = 'Application Error', 'Application Hang'
} | Group-Object { $_.Properties[0].Value } | Sort-Object Count -Descending |
    Select-Object -First 5 Count, Name |
    Format-Table -AutoSize | Out-String | Write-Host

$currentVersion = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion'
$renames = @{
    Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    Name = 'PendingFileRenameOperations'
    ErrorAction = 'SilentlyContinue'
}
$pending = @(
    if (Test-Path "$currentVersion\Component Based Servicing\RebootPending") {
        'Windows servicing'
    }
    if (Test-Path "$currentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        'Windows Update'
    }
    if (Get-ItemProperty @renames) { 'file renames' }
)
if ($pending) { Write-Warning "Restart pending for $($pending -join ', ')." }

$up = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
'Uptime: {0:N1} days' -f $up.TotalDays
# Fast Startup hibernates the kernel on shutdown, so only a restart resets this.
if ($up.TotalDays -gt $MaxUptimeDays) {
    Write-Warning ("Up for more than $MaxUptimeDays days: " +
        'a restart (not shut down) beats everything above.')
}
