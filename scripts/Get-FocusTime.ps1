<#
Prints today's focus time from ActivityWatch as JSON for the YASB focus_time
widget: {"active": "2h 15m", "top": "msedge 1h 5m"}. Active time is time not
AFK; the top app is the one focused longest during it.
#>

$ErrorActionPreference = 'Stop'

function Format-Duration([double]$Seconds) {
    $span = [TimeSpan]::FromSeconds($Seconds)
    if ($span.TotalHours -ge 1) { '{0}h {1}m' -f [int][Math]::Floor($span.TotalHours), $span.Minutes } else { '{0}m' -f $span.Minutes }
}

$today = [DateTimeOffset]::new([DateTime]::Today)
$period = '{0}/{1}' -f $today.ToString('o'), $today.AddDays(1).ToString('o')
$query = @(
    'afk = flood(query_bucket(find_bucket("aw-watcher-afk_")));'
    'active = filter_keyvals(afk, "status", ["not-afk"]);'
    'windows = flood(query_bucket(find_bucket("aw-watcher-window_")));'
    'apps = sort_by_duration(merge_events_by_keys(filter_period_intersect(windows, active), ["app"]));'
    'RETURN = {"active": sum_durations(active), "apps": limit_events(apps, 1)};'
)
$body = @{ timeperiods = @($period); query = $query } | ConvertTo-Json

try {
    $result = (Invoke-RestMethod -Method Post -Uri 'http://localhost:5600/api/0/query/' -Body $body -ContentType 'application/json' -TimeoutSec 5)[0]
    $top = if ($result.apps) { '{0} {1}' -f ($result.apps[0].data.app -replace '\.exe$'), (Format-Duration $result.apps[0].duration) } else { 'nothing yet' }
    @{ active = Format-Duration $result.active; top = $top } | ConvertTo-Json -Compress
}
catch {
    # ActivityWatch not running (yet): keep the widget readable.
    @{ active = '--'; top = 'ActivityWatch is not running' } | ConvertTo-Json -Compress
}
