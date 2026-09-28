#!/bin/sh
# Loads ~/dotfiles/config/tmux into rmux (rmux.conf starts it once the
# server answers). gpakosz's framework and TPM take minutes here, hundreds
# of `tmux` calls that each cost an MSYS sh and an rmux client, yet always
# end in the same options and keys. So the first full load is snapshotted
# and later starts source the snapshot (~0.6 s); a change to the config,
# the plugins or this folder makes the next start rebuild it.
cache=$WINHOME/.cache/rmux.conf
plugins=${TMUX_CONF%/*}/plugins
here=${0%/*}

if [ -f "$cache" ] && [ -z "$(find "$TMUX_CONF" "$TMUX_CONF_LOCAL" "$plugins" "$here" -newer "$cache" -print -quit 2>/dev/null)" ]; then
    tmux source-file "$cache"
    # What plugins start rather than set: aw-watcher-tmux's loop, and
    # continuum's restore (it restores only if @continuum-restore is on).
    "$plugins/aw-watcher-tmux/scripts/monitor-session-activity.sh" >/dev/null 2>&1 &
    "$plugins/tmux-continuum/scripts/continuum_restore.sh" >/dev/null 2>&1 &
    exit
fi

# tmux.conf.local's Linux default-command (fish) goes back to pwsh, and
# gpakosz's F (fpp, not installed here) is unbound.
tmux source-file "$TMUX_CONF" \; set -g default-command pwsh \; unbind F
# Helix is hx here, not helix, for tmux-resurrect's restore.
tmux set -ga @resurrect-processes ' hx'
# gpakosz runs TPM in a background job; snapshot once it has come and gone.
for _ in $(seq 60); do ps -ef | grep -q '[_]_apply_plugins' && break; sleep 1; done
while ps -ef | grep -q '[_]_apply_plugins'; do sleep 2; done
# gpakosz's r reload would skip the snapshot; reset.sh rebuilds it.
tmux bind r run-shell -b "$here/reset.sh"
mkdir -p "${cache%/*}"
{
    tmux show -g | sed 's/^/set -g /'
    tmux show -gw | sed 's/^/setw -g /'
    tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH | sed 's/^\([^=]*\)=\(.*\)$/setenv -g \1 "\2"/'
    tmux list-keys
} > "$cache.tmp" && mv "$cache.tmp" "$cache"
tmux display 'tmux config loaded'
