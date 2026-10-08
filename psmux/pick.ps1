# tmux-copycat/open stand-in: psmux copy-mode can't be driven by search
# commands, so scrape the pane's matches of one kind and pick with fzf.
# Enter opens (URLs, existing paths), ctrl-y copies.
param(
    [string]$Pane,
    [ValidateSet('url', 'path', 'hash', 'ip', 'digit', 'all')][string]$Kind = 'all'
)

$patterns = [ordered]@{
    url = 'https?://[^\s''"<>)\]]+'
    path = '(?:[A-Za-z]:|~|\.{1,2})?(?:[\\/][\w.@+-]+)+'
    hash = '\b[0-9a-f]{7,40}\b'
    ip = '\b(?:\d{1,3}\.){3}\d{1,3}\b'
    digit = '\b\d{4,}\b'
}
$regex = if ($Kind -eq 'all') { $patterns.Values -join '|' } else { $patterns[$Kind] }
$text = (psmux capture-pane -p -J -S -2000 -t $Pane) -join "`n"
$hits = @([regex]::Matches($text, $regex).Value | Select-Object -Unique)
[array]::Reverse($hits)  # newest first

$key, $pick = $hits | fzf --reverse --expect ctrl-y --prompt "$Kind (ctrl-y copy)> "
if (-not $pick) { return }
if ($key -eq 'ctrl-y') { Set-Clipboard $pick; return }

$path = $pick -replace '^~', $HOME
if ($pick -match '^https?://' -or (Test-Path -LiteralPath $path)) {
    Start-Process $path
}
else { Set-Clipboard $pick }  # hashes, IPs and dead paths have nothing to open
