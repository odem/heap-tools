#!/usr/bin/env bash
# gdb-plugins/install.sh -- peda + Pwngdb(angelheap) + gef + pwndbg for heap debugging
#
# 1. apt: gdb git python3 gcc libc6-dbg python3-six
# 2. sources: ~/peda (longld/peda), ~/Pwngdb (scwuaptx/Pwngdb), ~/gef (hugsy/gef),
#             ~/pwndbg (pwndbg/pwndbg, optional; venv built only if missing)
# 3. six fix:          ~/peda/lib/six.py 1.9.0 -> system six (gdb16/Python3.13
#                     "No module named 'six.moves'")  [backup: six.py.old-1.9-0]
# 4. angelheap patch:  tracemalloc() on glibc >= 2.41 (_int_malloc/_int_free removed
#                     -> breakpoints on public malloc/free, $rdi args)
#                     [backup: angelheap.py.orig, idempotent: TRACE_PUBLIC marker]
# 5. ~/.gdbinit (marker block): SyntaxWarning filter, init-peda/init-pwndbg/
#    init-gef/init-pwngdb defines, `pwn` combo define (init-pwndbg + init-pwngdb
#    + init-heapview if heapview feature installed), hook-run (angelheap re-init)
#    ~/.gdbinit_pwndbg -> source ~/pwndbg/gdbinit.py (gdb command file, NOT a symlink:
#    source on .py executes it as Python)
# 6. self-verification with /tmp test binaries
set -euo pipefail

HOME_DIR="${HOME:?}"
PASS=0; FAIL=0
log()  { printf '\n\033[1;36m[gdb-plugins]\033[0m %s\n' "$*"; }
info() { printf '         %s\n' "$*"; }
ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo"

gdbinit_block() { # $1=name, content on stdin
    local name="$1" init="$HOME_DIR/.gdbinit"
    touch "$init"
    sed -i "/^# >>> $name >>>$/,/^# <<< $name <<</d" "$init" 2>/dev/null || true
    printf '# >>> %s >>>\n' "$name" >> "$init"
    cat >> "$init"
    printf '# <<< %s <<<\n\n' "$name" >> "$init"
}
ensure_repo() { # dir url
    if [ -d "$1/.git" ]; then
        git -C "$1" pull --ff-only --quiet >/dev/null 2>&1 \
            || info "could not update $1 (offline?) -- keeping local copy"
    else
        git clone --quiet "$2" "$1"
    fi
}

# ---------------------------------------------------------------------------
log "1/6  apt packages"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq >/dev/null 2>&1 || info "apt update failed (offline?) -- continuing"
if $SUDO apt-get install -y gdb git python3 gcc libc6-dbg python3-six >/dev/null 2>&1; then
    ok "packages installed/present"
else
    bad "apt install failed -- check network/sources"
fi

# ---------------------------------------------------------------------------
log "2/6  plugin sources (~/peda ~/Pwngdb ~/gef ~/pwndbg)"
ensure_repo "$HOME_DIR/peda"   https://github.com/longld/peda.git     || bad "peda clone failed"
ensure_repo "$HOME_DIR/Pwngdb" https://github.com/scwuaptx/Pwngdb.git || bad "Pwngdb clone failed"
ensure_repo "$HOME_DIR/gef"    https://github.com/hugsy/gef.git       || bad "gef clone failed"
HAVE_PWNDBG=0
if [ -d "$HOME_DIR/pwndbg/.git" ] || git clone --quiet https://github.com/pwndbg/pwndbg.git "$HOME_DIR/pwndbg" 2>/dev/null; then
    git -C "$HOME_DIR/pwndbg" pull --ff-only --quiet >/dev/null 2>&1 || true
    if [ ! -d "$HOME_DIR/pwndbg/.venv" ]; then
        info "building pwndbg venv (first run, takes a while)..."
        (cd "$HOME_DIR/pwndbg" && ./setup.sh --update >/dev/null 2>&1) || info "pwndbg setup failed -- it stays optional"
    fi
    HAVE_PWNDBG=1
fi
[ -f "$HOME_DIR/peda/peda.py" ]     && ok "peda    present"      || bad "peda missing"
[ -f "$HOME_DIR/Pwngdb/pwngdb.py" ] && ok "Pwngdb present"      || bad "Pwngdb missing"
[ -f "$HOME_DIR/gef/gef.py" ]       && ok "gef     present"      || bad "gef missing"
[ "$HAVE_PWNDBG" = 1 ]              && ok "pwndbg  present"      || info "pwndbg unavailable (optional)"

# ---------------------------------------------------------------------------
log "3/6  peda six fix (bundled six 1.9.0 breaks on gdb16/Python3.13)"
SIX_SYS=/usr/lib/python3/dist-packages/six.py
if [ -f "$SIX_SYS" ]; then
    if grep -q '__version__ = "1.9.0"' "$HOME_DIR/peda/lib/six.py" 2>/dev/null; then
        [ -f "$HOME_DIR/peda/lib/six.py.old-1.9-0" ] || cp "$HOME_DIR/peda/lib/six.py" "$HOME_DIR/peda/lib/six.py.old-1.9-0"
        cp "$SIX_SYS" "$HOME_DIR/peda/lib/six.py"
        rm -rf "$HOME_DIR/peda/lib/__pycache__"
        ok "replaced bundled six 1.9.0 with system six"
    else
        ok "already fixed ($(grep -m1 __version__ "$HOME_DIR/peda/lib/six.py" 2>/dev/null || echo 'unknown'))"
    fi
else
    bad "system six.py not found -- install python3-six"
fi

# ---------------------------------------------------------------------------
log "4/6  angelheap patch (tracemalloc on glibc >= 2.41)"
if HOME="$HOME_DIR" python3 - <<'PYEOF' 2>/dev/null
import os, shutil, sys
p = os.path.join(os.environ["HOME"], "Pwngdb", "angelheap", "angelheap.py")
src = open(p).read()
if "TRACE_PUBLIC" in src:                     # already patched -> idempotent
    print("ALREADY_PATCHED")
    sys.exit(0)
shutil.copy(p, p + ".orig")                   # backup (kept, never overwritten)

def rep(old, new):
    global src
    assert src.count(old) == 1, "anchor not unique: %r" % old[:60]
    src = src.replace(old, new)

rep("system_mem = 0x21000\n",
    "system_mem = 0x21000\n\n"
    "# Pwngdb patch: when glibc >= 2.41 removed _int_malloc/_int_free, trace the\n"
    "# public malloc()/free() entry points instead (args are in rdi there, not rsi)\n"
    "TRACE_PUBLIC = False\n")

rep('''        if arch == "x86-64":
            reg = "$rsi"
            arg = int(gdb.execute("info register " + reg,to_string=True).split()[1].strip(),16)''',
    '''        if arch == "x86-64":
            reg = "$rdi" if TRACE_PUBLIC else "$rsi"
            arg = int(gdb.execute("info register " + reg,to_string=True).split()[1].strip(),16)''')

rep('''        if arch == "x86-64":
            reg = "$rsi"
            result = int(gdb.execute("info register " + reg,to_string=True).split()[1].strip(),16) + 0x10''',
    '''        if arch == "x86-64":
            if TRACE_PUBLIC:
                # public free(void *ptr): ptr in rdi is already the user pointer
                reg = "$rdi"
                result = int(gdb.execute("info register " + reg,to_string=True).split()[1].strip(),16)
            else:
                reg = "$rsi"
                result = int(gdb.execute("info register " + reg,to_string=True).split()[1].strip(),16) + 0x10''')

rep('''    mallocbp = Malloc_Bp_handler("*" + "_int_malloc")
    freebp = Free_Bp_handler("*" + "_int_free")
    memalignbp = Memalign_Bp_handler("*" + "_int_memalign")
    reallocbp = Realloc_Bp_handler("*" + "_int_realloc")''',
    '''    global TRACE_PUBLIC
    # glibc >= 2.41 removed _int_malloc/_int_free; fall back to public entry points
    int_syms = True
    for s in ("_int_malloc", "_int_free"):
        try:
            gdb.parse_and_eval(s)
        except Exception:
            int_syms = False
            break
    if int_syms:
        TRACE_PUBLIC = False
        mallocbp = Malloc_Bp_handler("*" + "_int_malloc")
        freebp = Free_Bp_handler("*" + "_int_free")
    else:
        TRACE_PUBLIC = True
        mallocbp = Malloc_Bp_handler("*" + "malloc")
        freebp = Free_Bp_handler("*" + "free")
    try:
        memalignbp = Memalign_Bp_handler("*" + "_int_memalign")
    except Exception:
        memalignbp = None
    try:
        reallocbp = Realloc_Bp_handler("*" + "_int_realloc")
    except Exception:
        reallocbp = None''')

open(p, "w").write(src)
print("PATCHED")
PYEOF
then ok "angelheap.py trace_malloc fallback in place"
else bad "angelheap patch failed"
fi

# ---------------------------------------------------------------------------
log "5/6  ~/.gdbinit (multiplexer) + ~/.gdbinit_pwndbg"
# migration: legacy file (old install_gdb.bash, no marker blocks) -> backup + reset;
# custom/unknown files are kept, only our block is appended
GDBINIT="$HOME_DIR/.gdbinit"
if [ -f "$GDBINIT" ] && ! grep -q '^# >>>' "$GDBINIT"; then
    [ -f "$HOME_DIR/.gdbinit.legacy" ] || cp "$GDBINIT" "$HOME_DIR/.gdbinit.legacy"
    grep -q '^# ~/.gdbinit -- generated by install_gdb.bash' "$GDBINIT" \
        && : > "$GDBINIT" || true   # || true: custom files (no signature) must not abort
fi
{
    echo "python"
    echo "import warnings"
    echo 'warnings.filterwarnings("ignore", category=SyntaxWarning)'
    echo "end"
    echo
    echo "define init-peda"
    echo "source ~/peda/peda.py"
    echo "end"
    echo "document init-peda"
    echo "Initializes the PEDA (Python Exploit Development Assistant for GDB) framework"
    echo "end"
    echo
    echo "define init-pwngdb"
    echo "source ~/peda/peda.py"
    echo "source ~/Pwngdb/pwngdb.py"
    echo "source ~/Pwngdb/angelheap/gdbinit.py"
    [ -f "$HOME_DIR/heapview/heapview.py" ] && echo "source ~/heapview/heapview.py"
    [ -f "$HOME_DIR/stackview/stackview.py" ] && echo "source ~/stackview/stackview.py"
    echo "end"
    echo "document init-pwngdb"
    echo "Initializes Pwngdb (pwngdb.py + angelheap) for heap debugging"
    echo "end"
    echo
    if [ "$HAVE_PWNDBG" = "1" ]; then
        echo "define init-pwndbg"
        echo "source ~/.gdbinit_pwndbg"
        echo "end"
        echo "document init-pwndbg"
        echo "Initializes PwnDBG"
        echo "end"
        echo
    fi
    if [ -f "$HOME_DIR/gef/gef.py" ]; then
        echo "define init-gef"
        echo "source ~/gef/gef.py"
        echo "end"
        echo "document init-gef"
        echo "Initializes GEF (GDB Enhanced Features)"
        echo "end"
        echo
    fi
    if [ "$HAVE_PWNDBG" = "1" ]; then
        echo "define pwn"
        echo "init-pwndbg"
        echo "init-pwngdb"
        echo "end"
        echo "document pwn"
        echo "Default combo: pwndbg + pwngdb (+peda/angelheap/heapview)"
        echo "end"
        echo
    fi
    echo "# re-init angelheap heap tracking on every 'run'"
    echo "define hook-run"
    echo "python"
    echo "try:"
    echo "    import angelheap"
    echo "    angelheap.init_angelheap()"
    echo "except Exception:"
    echo "    pass"
    echo "end"
    echo "end"
} | gdbinit_block gdb-plugins
if [ "$HAVE_PWNDBG" = "1" ]; then
    echo "source $HOME_DIR/pwndbg/gdbinit.py" > "$HOME_DIR/.gdbinit_pwndbg"
    ok "~/.gdbinit_pwndbg -> ~/pwndbg/gdbinit.py"
fi
grep -q 'define init-pwngdb' "$HOME_DIR/.gdbinit" \
    && ok "~/.gdbinit multiplexer written (backup: .gdbinit.legacy/.bak)" || bad "gdbinit block missing"

# ---------------------------------------------------------------------------
log "6/6  verification (/tmp test binaries)"
cat > /tmp/gtest.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    void *a = malloc(0x20);
    void *b = malloc(0x100);
    void *c = malloc(0x20);
    fprintf(stderr, "a=%p b=%p c=%p\n", a, b, c);
    free(b);
    free(a);
    free(c);
    return 0;
}
EOF
cat > /tmp/gdblfree.c <<'EOF'
#include <stdlib.h>
int main(void) {
    void *a = malloc(0x20);
    void *b = malloc(0x20);
    free(a);
    free(b);
    free(a);   /* double free -> tcache abort */
    return 0;
}
EOF
gcc -g -O0 -o /tmp/gtest     /tmp/gtest.c     || bad "gtest build failed"
gcc -g -O0 -o /tmp/gdblfree  /tmp/gdblfree.c  || bad "gdblfree build failed"
strip_ansi() { sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x01//g' -e 's/\x02//g'; }

cat > /tmp/gt-check.gdb <<'EOF'
set pagination off
init-pwngdb
starti
break gtest.c:9
continue
heapinfo
parseheap
quit
EOF
OUT=$(cd /tmp && timeout 150 gdb -q -batch -x /tmp/gt-check.gdb ./gtest 2>&1 || true)
echo "$OUT" | grep -q 'top:'  && ok "pwngdb heapinfo  -> arena/top/tcache"   || bad "heapinfo broken"
echo "$OUT" | grep -q 'Used'  && ok "pwngdb parseheap  -> chunk table"        || bad "parseheap broken"
N=$(echo "$OUT" | grep -c 'SyntaxWarning' || true)
[ "$N" -eq 0 ]                    && ok "no SyntaxWarnings (filter active)"  || bad "$N SyntaxWarnings"

cat > /tmp/gt-trace.gdb <<'EOF'
set pagination off
init-pwngdb
starti
break main
continue
tracemalloc on
continue
quit
EOF
OUT2=$(cd /tmp && timeout 150 gdb -q -batch -x /tmp/gt-trace.gdb ./gdblfree 2>&1 || true)
echo "$OUT2" | grep -q 'double free detected' && ok "tracemalloc -> double-free detection" || bad "tracemalloc broken"

cat > /tmp/gt-pwn.gdb <<'EOF'
set pagination off
pwn
starti
break gtest.c:9
continue
heap
quit
EOF
if [ "$HAVE_PWNDBG" = "1" ]; then
    OUT3=$(cd /tmp && timeout 150 gdb -q -batch -x /tmp/gt-pwn.gdb ./gtest 2>&1 || true)
    OUT3=$(echo "$OUT3" | strip_ansi)
    echo "$OUT3" | grep -q 'Top chunk' && ok "pwn combo -> pwndbg heap works"  || bad "pwn/heap broken"
else
    info "pwndbg missing -- skipping pwn check"
fi

cat > /tmp/gt-gef.gdb <<'EOF'
set pagination off
init-gef
starti
break gtest.c:9
continue
heap chunks
quit
EOF
if [ -f "$HOME_DIR/gef/gef.py" ]; then
    OUT4=$(cd /tmp && timeout 150 gdb -q -batch -x /tmp/gt-gef.gdb ./gtest 2>&1 || true)
    OUT4=$(echo "$OUT4" | strip_ansi)
    echo "$OUT4" | grep -q 'Chunk(addr=' && ok "gef -> heap chunks"             || bad "gef heap broken"
else
    info "gef missing -- skipping gef check"
fi
rm -f /tmp/gt-check.gdb /tmp/gt-trace.gdb /tmp/gt-pwn.gdb /tmp/gt-gef.gdb /tmp/gtest* /tmp/gdblfree*

echo
echo "  gdb-plugins: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1