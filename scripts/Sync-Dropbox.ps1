<#
Two-way Dropbox sync with rclone bisync, for a machine that can't run the
Dropbox app (Basic allows 3 devices; rclone uses the API and doesn't count).

  Hot   Org and Git, every 5 minutes: notes and the bare repos you push to.
  Rest  the rest of ~\Dropbox, every 6 hours.

Why tiers: rclone lists Dropbox one folder at a time (no ListR) and Dropbox
throttles bursts with 5-minute penalties, so the whole tree (~15-20k folders)
takes an hour or more to scan. Staying under the throttle means ~12 requests/s
in total: 8 for Hot (~1,000 folders, about a minute a run) and 4 for Rest, so
both can run side by side. node_modules is left out everywhere (generated, and
most of the files); .git is synced, but not git's *.lock files, which would
make git elsewhere think a command is still running. Keep the bare repos in Git
packed (git gc, receive.unpackLimit 1) so they stay a few files each. The
dropbox: remote needs its own app key (client_id): rclone's shared one is
throttled far harder.

Conflicts: when both sides changed a file, the newer keeps its name and the
other becomes NAME.conflictN (appended, so org-roam and the agenda never read
it as a note). New ones raise a Windows notification; -Action Resolve walks
them in Emacs ediff, loading ~/dotfiles/emacs/funcs/aam-sync.el itself (the
Emacs config doesn't load it).

Usage:
  pwsh -File .\scripts\Sync-Dropbox.ps1 -Resync -DryRun            # preview first Hot sync
  pwsh -File .\scripts\Sync-Dropbox.ps1 -Resync                    # first Hot sync (once)
  pwsh -File .\scripts\Sync-Dropbox.ps1 -Tier Rest -Resync -DryRun # same for the rest
  pwsh -File .\scripts\Sync-Dropbox.ps1 [-Tier Rest]               # one sync
  pwsh -File .\scripts\Sync-Dropbox.ps1 -Action Watch [-Tier Rest] # sync on its interval
  pwsh -File .\scripts\Sync-Dropbox.ps1 -Action Install            # both tiers at sign-in, hidden
  pwsh -File .\scripts\Sync-Dropbox.ps1 -Action Uninstall          # undo Install, stop the watchers
  pwsh -File .\scripts\Sync-Dropbox.ps1 -Action Resolve            # ediff the conflicts in Emacs
Logs: %LOCALAPPDATA%\windots\sync-dropbox-<tier>.log
#>

[CmdletBinding()]
param(
    [ValidateSet('Sync', 'Watch', 'Install', 'Uninstall', 'Resolve')]
    [string]$Action = 'Sync',
    [ValidateSet('Hot', 'Rest')]
    [string]$Tier = 'Hot',
    [string]$Root = "$HOME\Dropbox",
    # Percent of either side one run may delete; raise it for a run that is
    # meant to delete a lot (e.g. right after repacking git repos).
    [ValidateRange(1, 100)]
    [int]$MaxDelete = 25,
    [switch]$Resync,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$rclone = (Get-Command rclone -CommandType Application -ErrorAction SilentlyContinue).Source
if (-not $rclone) { throw 'rclone was not found. Install it with: scoop install rclone' }

$hot = 'Org', 'Git'
$tiers = @{
    # Pairs of local path and remote, requests per second, minutes between runs.
    Hot  = @{ Pairs = $hot | ForEach-Object { , @((Join-Path $Root $_), "dropbox:$_") }; Tps = 8; Minutes = 5; Exclude = @() }
    Rest = @{ Pairs = , @($Root, 'dropbox:'); Tps = 4; Minutes = 360; Exclude = $hot | ForEach-Object { "/$_/**" } }
}
$config = $tiers[$Tier]

$logDir = Join-Path $env:LOCALAPPDATA 'windots'
$log = Join-Path $logDir "sync-dropbox-$($Tier.ToLower()).log"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Invoke-Bisync([string]$Local, [string]$Remote) {
    # Keep the log to one generation of ~5MB.
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 5MB) {
        Move-Item -LiteralPath $log -Destination "$log.1" -Force
    }
    $arguments = @(
        'bisync', $Local, $Remote
        '--create-empty-src-dirs'
        '--compare', 'size,modtime'          # no hashing: re-reading every file each run is the slow part
        '--conflict-resolve', 'newer'        # both edited: keep the newer ...
        '--conflict-loser', 'num'            # ... and the other as file.conflict1
        '--resilient', '--recover'           # carry on after a failed run instead of demanding --resync
        '--max-lock', '2h'                   # one run per pair at a time; a crashed run's lock expires
        '--max-delete', $MaxDelete           # abort if a run would delete more of either side
        '--tpslimit', $config.Tps
        '--exclude', 'node_modules/**'
        '--exclude', '.git/*.lock', '--exclude', '.git/**/*.lock'   # git's own locks stay per machine
        # Symlinks elsewhere (into Org/skills); Dropbox's API shows them as
        # empty files, which clash with the folders they resolve to here.
        '--exclude', '.claude/skills/**'
        '--exclude', '.#*', '--exclude', '#*#', '--exclude', '*~'   # Emacs locks and backups
        '--exclude', 'desktop.ini', '--exclude', 'Thumbs.db', '--exclude', '.DS_Store'
        '--log-file', $log, '--log-level', 'INFO'
    )
    foreach ($pattern in $config.Exclude) { $arguments += '--exclude', $pattern }
    # The first run has no prior listings to compare against, so it merges both
    # sides (newer wins where both have a file) without propagating deletions.
    if ($Resync) { $arguments += '--resync', '--resync-mode', 'newer' }
    if ($DryRun) { $arguments += '--dry-run' }
    & $rclone @arguments | Out-Host   # keep rclone's output out of the return value
    $LASTEXITCODE
}

# Windows PowerShell has the WinRT toast API; pwsh doesn't, so hand it over.
function Show-Toast([string]$Title, [string]$Text) {
    $script = @"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
`$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
`$lines = `$xml.GetElementsByTagName('text')
[void]`$lines.Item(0).AppendChild(`$xml.CreateTextNode('$($Title -replace "'", "''")'))
[void]`$lines.Item(1).AppendChild(`$xml.CreateTextNode('$($Text -replace "'", "''")'))
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show([Windows.UI.Notifications.ToastNotification]::new(`$xml))
"@
    powershell.exe -NoProfile -Command $script
}

# The tier's NAME.conflictN files, kept in a list; a notification for new ones.
function Update-Conflicts {
    $list = Join-Path $logDir "dropbox-conflicts-$($Tier.ToLower()).txt"
    $before = if (Test-Path -LiteralPath $list) { @(Get-Content -LiteralPath $list) } else { @() }
    $found = foreach ($pair in $config.Pairs) {
        Get-ChildItem -LiteralPath $pair[0] -Recurse -File -Force -Filter '*.conflict*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.conflict\d+$' -and $_.FullName -notmatch '[\\/]node_modules[\\/]' } |
            ForEach-Object FullName
    }
    $found = @($found | Sort-Object)
    Set-Content -LiteralPath $list -Value $found
    $new = @($found | Where-Object { $_ -notin $before })
    if ($new) {
        Show-Toast "Dropbox: $($found.Count) sync conflict(s)" "Both sides changed $(Split-Path -Leaf ($new[0] -replace '\.conflict\d+$')). Resolve: Sync-Dropbox.ps1 -Action Resolve"
    }
}

function Invoke-Tier {
    $worst = 0
    foreach ($pair in $config.Pairs) {
        $code = Invoke-Bisync @pair
        if ($code -ne 0) { Write-Warning "bisync $($pair[1]) exited with $code; see $log"; $worst = $code }
    }
    if (-not $DryRun) { Update-Conflicts }
    $worst
}

switch ($Action) {
    'Sync' { exit (Invoke-Tier) }
    'Watch' {
        while ($true) {
            [void](Invoke-Tier)
            Start-Sleep -Seconds ($config.Minutes * 60)
        }
    }
    'Resolve' {
        # Through Emacs-Daemon.ps1: it starts the Doom daemon if need be and finds its
        # server file (a bare emacsclient would run ALTERNATE_EDITOR and hang).
        $elisp = (Join-Path $HOME 'dotfiles\emacs\funcs\aam-sync.el').Replace('\', '/')
        & (Join-Path $PSScriptRoot 'Emacs-Daemon.ps1') open doom -n -e "(progn (load `"$elisp`" nil t) (aam/sync-resolve-conflicts))"
    }
    'Install' {
        # Startup shortcuts, like setup\Install-Startup.ps1; conhost --headless
        # keeps Windows Terminal (the default terminal) from opening a tab.
        # First on PATH: there can be several (Store and Scoop builds).
        $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        $startup = [Environment]::GetFolderPath('Startup')
        $shell = New-Object -ComObject WScript.Shell
        foreach ($name in $tiers.Keys) {
            $shortcut = $shell.CreateShortcut((Join-Path $startup "Dropbox $name.lnk"))
            $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
            $shortcut.Arguments = '--headless "{0}" -NoProfile -File "{1}" -Action Watch -Tier {2}' -f $pwsh, $PSCommandPath, $name
            $shortcut.Save()
            Write-Host "Startup: Dropbox $name"
        }
    }
    'Uninstall' {
        # Undoes Install and stops the running watchers.
        $startup = [Environment]::GetFolderPath('Startup')
        foreach ($name in $tiers.Keys) {
            Remove-Item (Join-Path $startup "Dropbox $name.lnk") -ErrorAction SilentlyContinue
        }
        Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'Sync-Dropbox\.ps1.*-Action Watch' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "Stopped $($_.ProcessId)" }
        Write-Host 'Uninstalled'
    }
}
