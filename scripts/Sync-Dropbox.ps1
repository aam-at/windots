[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$LocalPath,

    [Parameter(Mandatory)]
    [string]$RemotePath,

    [ValidateSet('Push', 'Pull')]
    [string]$Direction = 'Push',

    [switch]$Mirror,
    [switch]$DryRun,

    [ValidateRange(1, 1440)]
    [int]$ScheduleMinutes,

    [switch]$InstallSchedule,
    [string]$TaskName = 'Rclone Dropbox Sync'
)

$rclone = Get-Command rclone -ErrorAction SilentlyContinue
if (-not $rclone) {
    throw 'rclone was not found. Install it with: scoop install rclone'
}

$local = [IO.Path]::GetFullPath($LocalPath)
if ($Direction -eq 'Push' -and -not (Test-Path -LiteralPath $local -PathType Container)) {
    throw "Local source folder does not exist: $local"
}

if ($InstallSchedule) {
    if (-not $ScheduleMinutes) { throw 'Use -ScheduleMinutes when installing a schedule.' }

    $scriptPath = $PSCommandPath.Replace('"', '\"')
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -LocalPath `"$local`" -RemotePath `"$RemotePath`" -Direction $Direction"
    if ($Mirror) { $arguments += ' -Mirror' }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $ScheduleMinutes) -RepetitionDuration (New-TimeSpan -Days 9999)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Description "rclone $Direction sync for $RemotePath" -Force | Out-Null
    Write-Host "Scheduled '$TaskName' every $ScheduleMinutes minute(s)."
    exit
}

if ($Direction -eq 'Push') {
    $source, $destination = $local, $RemotePath
}
else {
    $source, $destination = $RemotePath, $local
}

$command = if ($Mirror) { 'sync' } else { 'copy' }
$arguments = @($command, $source, $destination, '--log-level', 'INFO')
if ($DryRun) { $arguments += '--dry-run' }

& $rclone.Source @arguments
exit $LASTEXITCODE
