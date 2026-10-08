<#
Clears caches and temporary files: bun, uv, npm, pip, cargo, scoop, winget, docker,
the user temp folder, the Recycle Bin, thumbnail caches, crash dumps and, when
elevated, C:\Windows\Temp, the Windows Update download cache, Delivery
Optimization, CBS logs and minidumps. Files in use are skipped. Reports the free
space gained on the system drive. -Compact (elevated) also shuts down WSL and Docker
and compacts their virtual disks, which otherwise never shrink.

Usage:
  pwsh -File .\scripts\Optimize-Disk.ps1
  pwsh -File .\scripts\Optimize-Disk.ps1 -Deep        # also DISM component cleanup
                                                      # (slow)
  pwsh -File .\scripts\Optimize-Disk.ps1 -Compact     # also compact the WSL and
                                                      # Docker disks
  pwsh -File .\scripts\Optimize-Disk.ps1 -Elevate     # rerun as admin (UAC prompt)
  pwsh -File .\scripts\Optimize-Disk.ps1 -WhatIf      # list what would be removed
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Deep,
    [switch]$Compact,
    [switch]$Elevate
)

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\setup\Common.ps1')
if ($Elevate -and -not (Test-IsAdmin)) {
    return Invoke-ScriptElevated $PSCommandPath $PSBoundParameters
}

function Get-FreeGb { [math]::Round((Get-PSDrive $env:SystemDrive[0]).Free / 1GB, 2) }

function Clear-Folder($path, $filter = '*') {
    if (-not (Test-Path $path)) { return }
    $items = Get-ChildItem $path -Filter $filter -Force -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        if ($PSCmdlet.ShouldProcess($item.FullName, 'Remove')) {
            Remove-Item $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Quiet on success; a missing tool is skipped, a failing one (Docker not running) warns.
function Invoke-Tool($name, [string[]]$arguments) {
    if (-not (Test-Command $name)) { return }
    if (-not $PSCmdlet.ShouldProcess("$name $arguments", 'Run')) { return }
    $out = & $name @arguments 2>&1
    if ($LASTEXITCODE) {
        Write-Warning ("$name $arguments exited $LASTEXITCODE`: " +
            "$($out | Select-Object -Last 1)")
    }
}

# Compacts every WSL distro's and Docker Desktop's VHDX, run after the fstrim above
# so the freed blocks are zeroed. Sparse VHDX files hand space back on their own.
function Compress-WslDisks {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $distros = Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object {
        $base = $_.GetValue('BasePath') -replace '^\\\\\?\\'
        Join-Path $base ($_.GetValue('VhdFileName') ?? 'ext4.vhdx')
    }
    $vhdx = @{
        Path = "$env:LOCALAPPDATA\Docker\wsl"
        Recurse = $true
        Filter = '*.vhdx'
        ErrorAction = 'SilentlyContinue'
    }
    $docker = Get-ChildItem @vhdx | ForEach-Object FullName
    $disks = @($distros; $docker) | Where-Object {
        (Test-Path $_) -and
        -not ((Get-Item $_).Attributes -band [IO.FileAttributes]::SparseFile)
    }
    if (-not $disks) { return }
    if ($PSCmdlet.ShouldProcess('WSL and Docker Desktop', 'Shut down')) {
        Stop-Process -Name 'Docker Desktop' -Force -ErrorAction SilentlyContinue
        wsl --shutdown
    }
    $gb = { [math]::Round((Get-Item $disk).Length / 1GB, 1) }
    $commands = New-TemporaryFile -WhatIf:$false
    try {
        foreach ($disk in $disks) {
            if (-not $PSCmdlet.ShouldProcess($disk, 'Compact')) { continue }
            $was = & $gb
            Set-Content $commands @(
                "select vdisk file=`"$disk`""
                'attach vdisk readonly'
                'compact vdisk'
                'detach vdisk'
            )
            $out = diskpart /s $commands
            if ($LASTEXITCODE) {
                Write-Warning ("diskpart failed on $disk`: " +
                    "$($out | Select-Object -Last 1)")
            }
            else { "Compacted $disk`: $was GB -> $(& $gb) GB" }
        }
    }
    finally { Remove-Item $commands }
}

$env:WSL_UTF8 = 1   # wsl.exe prints UTF-16 otherwise
$before = Get-FreeGb

# Package manager caches
Invoke-Tool bun   'pm', 'cache', 'rm'
Invoke-Tool uv    'cache', 'clean'
Invoke-Tool npm   'cache', 'clean', '--force'
Invoke-Tool pip   'cache', 'purge'
Invoke-Tool scoop 'cleanup', '*'      # old app versions
Invoke-Tool scoop 'cache', 'rm', '*'  # every download, current ones too
Clear-Folder "$HOME\.cargo\registry\cache"
Clear-Folder "$env:LOCALAPPDATA\Temp\WinGet"

# Containers and WSL (WSL sparse VHDs need a shutdown, so only trim here)
Invoke-Tool docker 'system', 'prune', '-f'
Invoke-Tool wsl    '-u', 'root', 'fstrim', '-av'

# User junk (the icon cache lives in Optimize-System -RebuildCaches)
Clear-Folder $env:TEMP
Clear-Folder "$env:LOCALAPPDATA\CrashDumps"
Clear-Folder "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" 'thumbcache_*.db'
if ($PSCmdlet.ShouldProcess('Recycle Bin', 'Empty')) {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
}

# System junk
if (Test-IsAdmin) {
    Clear-Folder "$env:SystemRoot\Temp"
    Clear-Folder "$env:SystemRoot\Minidump"
    Clear-Folder "$env:SystemRoot\Logs\CBS" '*.log'
    if ($PSCmdlet.ShouldProcess('Delivery Optimization cache', 'Clear')) {
        Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
    }
    if ($PSCmdlet.ShouldProcess('Windows Update download cache', 'Clear')) {
        Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
        try { Clear-Folder "$env:SystemRoot\SoftwareDistribution\Download" }
        finally { Start-Service wuauserv, bits -ErrorAction SilentlyContinue }
    }
    if ($Deep) {
        Invoke-Tool dism '/Online', '/Cleanup-Image', '/StartComponentCleanup'
    }
    if ($Compact) { Compress-WslDisks }
}
else {
    Write-Warning ("Not elevated: skipped $env:SystemRoot\Temp, Windows Update, " +
        'Delivery Optimization, CBS logs, minidumps, DISM and -Compact.')
}

$after = Get-FreeGb
$gained = [math]::Round($after - $before, 2)
"Free on $env:SystemDrive $before GB -> $after GB ($gained GB)"
