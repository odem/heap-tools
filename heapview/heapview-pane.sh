#!/usr/bin/env bash
# heapview-pane.sh -- dedicated pane for ONE heap view (run in its own tmux pane)
#
#   gdb-tmux-hv-heapinfo   (alias)            # or raw:
#   tmux split-window -h 'bash ~/heapview/heapview-pane.sh heapinfo'
#   tmux split-window -h 'bash ~/heapview/heapview-pane.sh arena'
#   tmux split-window -h 'bash ~/heapview/heapview-pane.sh parseheap'  # ANY view name
#
# Self-registering: every loop we touch /tmp/gdb-view-req/<view> -- gdb's heapview
# hook writes EVERY requested view file (/tmp/gdb-view-<view>.txt) on every stop.
# No `heapview <views>` setup needed: just open the pane (request expires ~5s
# after the pane closes). Shows ONLY that view's file, refreshed every second.
VIEW="${1:-heapinfo}"
FILE="/tmp/gdb-view-${VIEW}.txt"
REQ_DIR=/tmp/gdb-view-req
REQ="$REQ_DIR/$VIEW"
mkdir -p "$REQ_DIR"
# run directly (no tmux)? then show how to leave, and keep a scrollback hint
if [ -z "${TMUX:-}" ]; then
    printf -- '-- heapview [%s] -- running in THIS terminal; Ctrl-C to quit --\n' "$VIEW"
fi
while :; do
    touch "$REQ"
    clear
    printf -- '-- heapview [%s] %s --\n\n' "$VIEW" "$(date +%H:%M:%S)"
    cat "$FILE" 2>/dev/null || echo "(no data yet: start gdb, run pwn (or init-pwngdb), then break/step)"
    sleep 1
done