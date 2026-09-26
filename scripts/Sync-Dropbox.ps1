<#
Dropbox on a machine that can't run the Dropbox app (Basic allows 3 devices;
rclone uses the API and doesn't count). Two parts:

  Org      ~\Dropbox\Org, a real local folder, two-way synced with rclone
           bisync every few minutes. node_modules and .git are left out: they
           are most of the files (38k of 48k), change in bursts, and are what
           corrupts under file sync.
  The rest dropbox: mounted at ~\Dropbox-Cloud (needs WinFsp), downloaded on
           open and cached. It hides Org, so notes have one way in.

Why not bisync everything: rclone lists Dropbox one folder at a time (no ListR)
and Dropbox throttles bursts with 5-minute penalties, so a full scan of ~15-20k
folders takes 25-35 minutes. --tpslimit 12 stays under the throttle (~10
folders/s); Org without node_modules/.git is ~700 folders, ~1 minute a run.
The dropbox: remote needs its own app key (client_id): rclone's shared one is
throttled far harder.

Usage:
  pwsh -File .\scripts\Sync-Dropbox.ps1 -Resync -DryRun   # preview the first sync
  pwsh -File .\scripts\Sync-Dropbox.ps1 -Resync           # first sync (once)
  pwsh -File .\scripts\Sync-Dropbox.ps1                   # one sync
  pwsh -File .\scripts\Sync-Dropbox.ps1 -Action Watch     # sync every -Minutes
  pwsh -File .\scripts\Sync-Dropbox.ps1 -Action Mount     # mount the rest
  pwsh -File .\scripts\Sync-Dropbox.ps1 -Action Install   # both at sign-in, hidden
#>

[CmdletBinding()]
param(
    [ValidateSet('Sync', 'Watch', 'Mount', 'Install')]
    [string]$Action = 'Sync',
    [string]$LocalPath = "$HOME\Dropbox\Org",
    [string]$RemotePath = 'dropbox:Org',
    [string]$MountPath = "$HOME\Dropbox-Cloud",
    [ValidateRange(1, 1440)]
    [int]$Minutes = 5,
    [switch]$Resync,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$rclone = (Get-Command rclone -CommandType Application -ErrorAction SilentlyContinue).Source
if (-not $rclone) { throw 'rclone was not found. Install it with: scoop install rclone' }

$logDir = Join-Path $env:LOCALAPPDATA 'windots'
$log = Join-Path $logDir 'sync-dropbox.log'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
# Under Dropbox's burst throttle: ~10 folders/s with no 5-minute penalties.
$throttle = @('--tpslimit', '12')

function Invoke-Bisync {
    # Keep the log to one generation of ~5MB.
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 5MB) {
        Move-Item -LiteralPath $log -Destination "$log.1" -Force
    }
    $arguments = @(
        'bisync', $LocalPath, $RemotePath
        '--create-empty-src-dirs'
        '--compare', 'size,modtime'          # no hashing: re-reading every file each run is the slow part
        '--conflict-resolve', 'newer'        # both edited: keep the newer ...
        '--conflict-loser', 'num'            # ... and the other as file.conflict1
        '--resilient', '--recover'           # carry on after a failed run instead of demanding --resync
        '--max-lock', '10m'                  # one run at a time; a crashed run's lock expires
        '--max-delete', '25'                 # abort if a run would delete >25% of either side
        '--exclude', 'node_modules/**'
        '--exclude', '.git/**'
        '--exclude', '.#*', '--exclude', '#*#', '--exclude', '*~'   # Emacs locks and backups
        '--exclude', 'desktop.ini', '--exclude', 'Thumbs.db', '--exclude', '.DS_Store'
        '--log-file', $log, '--log-level', 'INFO'
    ) + $throttle
    # The first run has no prior listings to compare against, so it merges both
    # sides (newer wins where both have a file) without propagating deletions.
    if ($Resync) { $arguments += '--resync', '--resync-mode', 'newer' }
    if ($DryRun) { $arguments += '--dry-run' }
    & $rclone @arguments | Out-Host   # keep rclone's output out of the return value
    $LASTEXITCODE
}

switch ($Action) {
    'Sync' {
        $code = Invoke-Bisync
        if ($code -ne 0) { Write-Warning "bisync exited with $code; see $log" }
        exit $code
    }
    'Watch' {
        while ($true) {
            [void](Invoke-Bisync)
            Start-Sleep -Seconds ($Minutes * 60)
        }
    }
    'Mount' {
        # The mount point must not exist yet; WinFsp creates it.
        if (Test-Path -LiteralPath $MountPath) { throw "$MountPath already exists; the mount creates it." }
        & $rclone mount dropbox: $MountPath `
            --vfs-cache-mode full --vfs-cache-max-size 20G --vfs-cache-max-age 720h `
            --dir-cache-time 1000h --poll-interval 1m `
            --exclude '/Org/**' --volname Dropbox `
            --log-file (Join-Path $logDir 'mount-dropbox.log') --log-level NOTICE @throttle
        exit $LASTEXITCODE
    }
    'Install' {
        # Startup shortcuts, like setup\Install-Startup.ps1; conhost --headless
        # keeps Windows Terminal (the default terminal) from opening a tab.
        $pwsh = (Get-Command pwsh -CommandType Application).Source
        $startup = [Environment]::GetFolderPath('Startup')
        $shell = New-Object -ComObject WScript.Shell
        foreach ($run in 'Watch', 'Mount') {
            $shortcut = $shell.CreateShortcut((Join-Path $startup "Dropbox $run.lnk"))
            $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
            $shortcut.Arguments = '--headless "{0}" -NoProfile -File "{1}" -Action {2} -Minutes {3}' -f $pwsh, $PSCommandPath, $run, $Minutes
            $shortcut.Save()
            Write-Host "Startup: Dropbox $run"
        }
    }
}
