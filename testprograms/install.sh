#!/usr/bin/env bash
# testprograms/install.sh -- build the heap test binaries into <repo>/out
#
#   out/heaptest -- 3 mallocs + frees (break at line 9 = after the mallocs)
#   out/dblfree  -- double free -> tcache abort (tracemalloc demo)
#
# out/ is repo-local (next to the Makefile) and gitignored (.gitignore).
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
DEST="$ROOT/out"
PASS=0; FAIL=0
log()  { printf '\n\033[1;36m[testprograms]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }

log "1/2  build -> $DEST (repo-local, gitignored)"
mkdir -p "$DEST"
if gcc -g -O0 -o "$DEST/heaptest" "$SRC/heaptest.c" \
   && gcc -g -O0 -o "$DEST/dblfree"  "$SRC/dblfree.c"; then
    ok "heaptest + dblfree built in $DEST"
else
    bad "build failed (is gcc installed?)"
fi

log "2/2  verify"
"$DEST/heaptest" >/dev/null 2>&1 && ok "heaptest runs (exit 0)" || bad "heaptest failed"
OUT=$("$DEST/dblfree" 2>&1 || true)
echo "$OUT" | grep -q 'double free detected in tcache' \
    && ok "dblfree aborts with tcache double-free message" || bad "dblfree: expected tcache abort"

echo
echo "  testprograms: $PASS passed, $FAIL failed"
echo "  usage (from repo root): gdb -q out/heaptest ; (gdb) pwn ; (gdb) starti ; (gdb) b heaptest.c:9 ; (gdb) c"
echo "  clean: make clean   (removes $DEST)"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1