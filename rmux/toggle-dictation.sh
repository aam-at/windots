#!/bin/sh
# dotfiles' tmux.conf.local binds S to toggle-dictation.sh (Linux: pw-record and
# whisper.cpp); on Windows that name lands here, on rmux's PATH, and hands the
# pane in DICTATION_TMUX_PANE to the native recorder.
DICTATION_TMUX=rmux exec "$WINHOME/windots/yasb/dictation/dictate.exe"
