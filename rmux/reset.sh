#!/bin/sh
# Drops the config snapshot and reloads ~/dotfiles/config/tmux the long way,
# saving a new one (see load.sh); sessions stay. Bound to prefix + r, as
# gpakosz's reload; from a shell:
#   rmux run-shell -b '"${TMUX_PROGRAM%/*}/reset.sh"'
rm -f "$WINHOME/.cache/rmux.conf"
tmux display 'Reloading the tmux config, which takes a few minutes...'
exec "${0%/*}/load.sh"
