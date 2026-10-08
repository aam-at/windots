# tmux-fzf stand-in: fuzzy-pick any window across sessions and jump to it.
# list-windows, since psmux's list-panes -a reports wrong pane indexes.
$format = '#{session_name}:#{window_index}', '#{window_name}',
'#{pane_current_command}', '#{pane_current_path}' -join "`t"
$pick = psmux list-windows -a -F $format |
    fzf --delimiter "`t" --tabstop 4 --reverse --prompt 'window> '
if ($pick) { psmux switch-client -t ($pick -split "`t")[0] }
