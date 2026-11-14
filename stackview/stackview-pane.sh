#!/usr/bin/env bash
# stackview-pane.sh -- dedicated pane for ONE stack view (run in its own tmux pane)
#
#   gdb-tmux-sv-stack   (alias)          # or raw:
#   tmux split-window -h 'bash ~/stackview/stackview-pane.sh stack'
#   tmux split-window -h 'bash ~/stackview/stackview-pane.sh frame'
#
# Self-registering: every loop we touch /tmp/gdb-stackview-req/<view> -- gdb's
# stackview hook writes EVERY requested view file (/tmp/gdb-stackview-<view>.txt)
# on every stop. No `stackview <views>` setup needed: just open the pane.
# Views: stack (raw stack memory from rsp), frame (current stackframe),
#         or any gdb command name (e.g. bt).
VIEW="${1:-stack}"
FILE="/tmp/gdb-stackview-${VIEW}.txt"
REQ_DIR=/tmp/gdb-stackview-req
REQ="$REQ_DIR/$VIEW"
mkdir -p "$REQ_DIR"
# run directly (no tmux)? then show how to leave, and keep a scrollback hint
if [ -z "${TMUX:-}" ]; then
    printf -- '-- stackview [%s] -- running in THIS terminal; Ctrl-C to quit --\n' "$VIEW"
fi
while :; do
    touch "$REQ"
    clear
    printf -- '-- stackview [%s] %s --\n\n' "$VIEW" "$(date +%H:%M:%S)"
    cat "$FILE" 2>/dev/null || echo "(no data yet: start gdb, run pwn (or init-stackview), then break/step)"
    sleep 1
done