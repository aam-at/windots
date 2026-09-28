# tmux-fzf stand-in: fuzzy-pick any window across sessions and jump to it.
# list-windows, since psmux's list-panes -a reports wrong pane indexes.
$pick = psmux list-windows -a -F "#{session_name}:#{window_index}`t#{window_name}`t#{pane_current_command}`t#{pane_current_path}" |
    fzf --delimiter "`t" --tabstop 4 --reverse --prompt 'window> '
if ($pick) { psmux switch-client -t ($pick -split "`t")[0] }
