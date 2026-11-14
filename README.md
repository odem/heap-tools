# heap-tools

GDB heap- & stack-debugging toolkit for glibc — a small repo of **per-feature
installers** orchestrated by a Makefile.

| Feature | What you get |
|---|---|
| **gdb-plugins** | peda + Pwngdb/angelheap + GEF + pwndbg, pre-patched to work on **gdb 16 / Python 3.13 / glibc 2.41** (Debian 13) |
| **heapview** | a **separate tmux pane that shows ONLY `heapinfo`**, auto-refreshed on *every* break/step |
| **stackview** | same design for the **stack**: raw stack memory pane + current-stackframe pane |
| **testprograms** | tiny heap test binaries (`heaptest`, `dblfree`) to try everything on |

Everything is **idempotent** (re-run anytime) and **self-verifying**
(each installer prints PASS/FAIL and exits non-zero on failure).

> **Convention: the program you debug lives in `out/`.**
> All examples in this README assume the binary is in the repo-local **`out/`**
> folder (created by `make`, **gitignored** — never committed).
> The test binaries land there (`out/heaptest`, `out/dblfree`); build or drop
> your **own** targets there too (e.g. `gcc -g -O0 -o out/myexp myexp.c`),
> then every example applies verbatim: `gdb -q out/myexp`.
> `make clean` wipes it.

---

## Quickstart

```bash
# on the target machine (e.g. the testvm):
git clone <this repo>       # or: scp -r heap-tools root@10.10.123.222:/root/
cd heap-tools
make                        # installs ALL features, in order
```

or install features individually:

```bash
make heapview       # 10 checks
make stackview      #  9 checks
make gdb-plugins    # 15 checks
make testprograms   #  3 checks
```

Expected output:

```
heapview:      10 passed, 0 failed
stackview:      9 passed, 0 failed
gdb-plugins:   15 passed, 0 failed
testprograms:   3 passed, 0 failed
```

---

## The 10-second demo (copy & paste)

Two terminal windows side by side — normal gdb on the left, **only the heap
view** on the right, updating itself on every break/step:

```bash
# terminal: start a tmux session
tmux new -s pwn

# --- inside tmux: open one pane PER view (aliases from `make heapview`) ---
gdb-tmux-hv-heapinfo                  # pane with the heapinfo view
gdb-tmux-hv-arena                     # pane with the arena view
# (raw form: tmux split-window -h 'bash ~/heapview/heapview-pane.sh heapinfo')

# --- now in the left pane: start gdb (binaries live in out/, from repo root) ---
gdb -q out/heaptest
```

```gdb
(gdb) pwn                  # load the default stack (pwndbg + pwngdb + heapview)
(gdb) starti               # stop at loader entry
(gdb) b heaptest.c:9        # break AFTER the mallocs (heap exists now)
(gdb) c                    # continue -> watch the right pane update
(gdb) n                    # single-step -> pane updates again, no typing
```

The right panes now show, on every stop (**one file per view** — default views:
`heapinfo` + `@arena`):

**pane B — heapinfo view** (`/tmp/gdb-view-heapinfo.txt`):

```
stop: main at heaptest.c:11  (pc 0x5555555551c1, pid 36298)

(0x20)     fastbin[0]: 0x0
(0x30)     fastbin[1]: 0x0
(0x40)     fastbin[2]: 0x0
...
                  top: 0x555555559400 (size : 0x20c00)
       last_remainder: 0x0 (size : 0x0)
            unsortbin: 0x0
(0x110)   tcache_entry[15](1): 0x5555555592d0
```

**pane C — arena view** (`/tmp/gdb-view-arena.txt`, builtin `@arena`):

```
stop: main at heaptest.c:11  (pc 0x5555555551c1, pid 36298)

arena            : 0x7ffff7f9cac0 (main_arena)
mutex            : 0x0
flags            : 0x0
have_fastchunks  : 0x0
top              : 0x555555559400 (size 0x20c00)
last_remainder   : 0x0
next             : 0x7ffff7f9cac0 (self)
next_free        : 0x0
attached_threads : 0x1
system_mem       : 0x21000
max_system_mem   : 0x21000
fastbinsY        : empty
binmap           : 0x0, 0x0, 0x0, 0x0
```

No `heapinfo` retyped, no gdb window cluttered — that's the whole point of
`heapview`.

---

## Usage

### Plugin loading (gdb)

| Command | Loads | Use for |
|---|---|---|
| `pwn` | pwndbg + pwngdb (+peda, angelheap, heapview) | **default** — everything |
| `init-pwngdb` | peda + pwngdb + angelheap | `heapinfo`, `parseheap`, `tracemalloc` |
| `init-pwndbg` | pwndbg only | `heap`, `vis`, `bins`, `arenas` |
| `init-gef` | GEF | `heap chunks/bins/arenas`, GEF context UI |
| `init-peda` | PEDA only | PEDA classics (`pattern`, `find`, ...) |

### Heap commands after `pwn`

(examples use the test program `out/heaptest`; same flow for your own `out/<target>)`

```gdb
(gdb) starti                          # stop at entry FIRST (loads libc)
(gdb) b heaptest.c:9                  # break somewhere AFTER a malloc ran
(gdb) c
```

pwngdb / angelheap:

```gdb
(gdb) heapinfo                        # arena: fastbins, top, unsorted, tcache
(gdb) heapinfoall                     # same, for all threads
(gdb) parseheap                       # full chunk table (addr/size/status/fd/bk)
(gdb) heapbase                        # heap base address
(gdb) chunkptr 0x5555555592a0         # chunk info from a USER pointer
(gdb) chunkinfo 0x555555559290        # chunk info from a CHUNK address
(gdb) b main ; c ; tracemalloc on ; c # trace every malloc/free, flag double frees
```

pwndbg:

```gdb
(gdb) heap                            # all chunks
(gdb) vis                             # visual heap dump
(gdb) bins                            # tcache/fast/unsorted/small/large
(gdb) arenas                          # arena <-> heap mapping
```

GEF (note: subcommands!):

```gdb
(gdb) heap chunks
(gdb) heap bins
(gdb) heap arenas
```

### heapview (auto views — one file & one pane PER view)

The hook (`~/heapview/heapview.py`, loaded via `pwn`, `init-pwngdb` or `init-heapview`)
refreshes the configured **views** on **every** stop (break, step, next,
signal) — **each view into its own file**, so you can dedicate one pane per view:

| view | file | pane |
|---|---|---|
| `heapinfo` (pwngdb cmd) | `/tmp/gdb-view-heapinfo.txt` | `heapview-pane.sh heapinfo` |
| `@arena` (**builtin**) | `/tmp/gdb-view-arena.txt` | `heapview-pane.sh arena` |
| any command (e.g. `parseheap`) | `/tmp/gdb-view-parseheap.txt` | `heapview-pane.sh parseheap` |

The builtin `@arena` view = formatted `main_arena` status — its address plus
the values from the `malloc_state` struct itself (mutex, flags,
have_fastchunks, top + size, last_remainder, next, next_free,
attached_threads, system_mem, max_system_mem, fastbinsY, binmap).
Each view file contains a **stop header** (function, file:line, pc, pid) +
the view output. View → file name: `@`/spaces stripped/underscored.

**Panes self-register their view**: every pane touches
`/tmp/gdb-view-req/<view>` once per second; the hook writes **every**
requested view on every stop (requests expire ~5s after the pane closes).
So you can open a pane for **any** view name — e.g. `gdb-tmux-hv-parseheap`, or
raw `bash ~/heapview/heapview-pane.sh parseheap` — and its file gets
written automatically, no `heapview <views>` setup needed.

Customize **which** views get written (in gdb):

```gdb
(gdb) heapview                          # status: views + their files + pane cmds
(gdb) heapview off                       # stop writing the files
(gdb) heapview on                        # resume
(gdb) heapview default                   # reset to [heapinfo, @arena]
(gdb) heapview heapinfo parseheap @arena     # three views (three files/panes)
(gdb) heapview @arena                    # ONLY the arena view
(gdb) heapview info registers            # any command (file: gdb-view-info_registers.txt)
```

```bash
# dedicated pane PER view (also works outside tmux, e.g. 2nd terminal):
bash ~/heapview/heapview-pane.sh heapinfo   # default view
bash ~/heapview/heapview-pane.sh arena
# ... or in tmux:
tmux split-window -h 'bash ~/heapview/heapview-pane.sh heapinfo'
tmux split-window -h 'bash ~/heapview/heapview-pane.sh arena'
```

Because it's just a file, you can consume it however you like:

```bash
watch -c cat /tmp/gdb-view-arena.txt    # plain terminal, 2s refresh
```

### Bash aliases (`gdb-tmux-*` / `gdb-hv-*` / `gdb-sv-*`) — view panes

The aliases live in **dedicated files** in this repo —
`heapview/.bashrc_alias_gdb` and `stackview/.bashrc_alias_gdb_stack` — which
the installers copy to **`/etc/bash_aliases.d/`** (made **executable**):

Two kinds of aliases:

- **`gdb-tmux-*`** — open a tmux **pane** with the view (run **inside tmux**)
- **`gdb-hv-*` / `gdb-sv-*`** — run the view pane **directly in this terminal**
  (**no tmux needed** — e.g. second terminal beside gdb; `Ctrl-C` to quit)

```bash
# /etc/bash_aliases.d/.bashrc_alias_gdb        (make heapview):
# inside tmux: split a pane
alias gdb-tmux-hv-heapinfo='tmux split-window -h "bash ~/heapview/heapview-pane.sh heapinfo"'
alias gdb-tmux-hv-arena='tmux split-window -h "bash ~/heapview/heapview-pane.sh arena"'
alias gdb-tmux-hv-parseheap='tmux split-window -h "bash ~/heapview/heapview-pane.sh parseheap"'
# no tmux: run the pane in THIS terminal (Ctrl-C to quit)
alias gdb-hv-heapinfo='bash ~/heapview/heapview-pane.sh heapinfo'
alias gdb-hv-arena='bash ~/heapview/heapview-pane.sh arena'
alias gdb-hv-parseheap='bash ~/heapview/heapview-pane.sh parseheap'

# /etc/bash_aliases.d/.bashrc_alias_gdb_stack  (make stackview):
alias gdb-tmux-sv-stack='tmux split-window -h "bash ~/stackview/stackview-pane.sh stack"'
alias gdb-tmux-sv-frame='tmux split-window -h "bash ~/stackview/stackview-pane.sh frame"'
alias gdb-sv-stack='bash ~/stackview/stackview-pane.sh stack'
alias gdb-sv-frame='bash ~/stackview/stackview-pane.sh frame'

# ~/.bashrc (marker blocks written by the installers; Debian bash does NOT
# source /etc/bash_aliases.d/ by default, hence the explicit source lines):
[ -f /etc/bash_aliases.d/.bashrc_alias_gdb ] && . /etc/bash_aliases.d/.bashrc_alias_gdb
[ -f /etc/bash_aliases.d/.bashrc_alias_gdb_stack ] && . /etc/bash_aliases.d/.bashrc_alias_gdb_stack
```

Usage (new shells pick them up automatically; existing ones: `source ~/.bashrc`):

```bash
# inside tmux:
gdb-tmux-hv-heapinfo    # pane on the right: heapinfo view
gdb-tmux-hv-arena       # pane on the right: arena view
gdb-tmux-sv-stack       # pane on the right: raw stack memory
gdb-tmux-sv-frame       # pane on the right: current stackframe

# WITHOUT tmux (directly in a terminal, e.g. a second window beside gdb):
gdb-hv-heapinfo         # this terminal becomes the heapinfo view (Ctrl-C quits)
gdb-hv-arena
gdb-sv-stack            # this terminal becomes the raw-stack view
gdb-sv-frame
```

The `gdb-tmux-*` aliases call `tmux split-window`, so they only work
**inside tmux**. The plain aliases work **anywhere** — same pane script,
just without the tmux wrapper (prints a "Ctrl-C to quit" hint when run
outside tmux).

Any **view name** works — to add your own alias, **edit the repo alias file**
(`heapview/.bashrc_alias_gdb` or `stackview/.bashrc_alias_gdb_stack`) and
re-run `make heapview` / `make stackview`:

```bash
alias gdb-tmux-hv-bins='tmux split-window -h "bash ~/heapview/heapview-pane.sh bins"'
alias gdb-hv-bins='bash ~/heapview/heapview-pane.sh bins'
```

> Why not a gdb TUI layout? gdb's TUI only supports fixed windows
> (`src`/`asm`/`regs`/`cmd`): `tui new-layout x heapinfo 1` →
> `Unknown window "heapinfo"`. Hence stop-hook → file → pane.

### stackview (auto stack views — same design)

`make stackview` mirrors heapview for the **stack** — two builtin views,
**one file & one pane per view**, refreshed on **every** stop:

| view | file | pane |
|---|---|---|
| `@stack` (**builtin**) | `/tmp/gdb-stackview-stack.txt` | `stackview-pane.sh stack` |
| `@frame` (**builtin**) | `/tmp/gdb-stackview-frame.txt` | `stackview-pane.sh frame` |
| any command (e.g. `bt`) | `/tmp/gdb-stackview-bt.txt` | `stackview-pane.sh bt` |

- **`@stack`** — **raw stack memory**: `rsp`, `rbp`, frame size
  (`rbp-rsp`) and a 32-qword hexdump from `rsp` upward
- **`@frame`** — **current stackframe**: gdb `info frame` — stack level,
  frame address, `rip`/`rbp`/`rsp`, saved registers, caller frame, argument
  list location...
- Panes **self-register** (same as heapview): they touch
  `/tmp/gdb-stackview-req/<view>` every second; bare names map to builtins
  (`stack` → `@stack`, `frame` → `@frame`)
- Each view file contains the **stop header** (function, file:line, pc, pid)
  + the view output

```bash
gdb-tmux-sv-stack         # alias: pane with raw stack memory (inside tmux)
gdb-tmux-sv-frame          # alias: pane with the current stackframe
# raw:  tmux split-window -h 'bash ~/stackview/stackview-pane.sh stack'
```

```gdb
(gdb) pwn                         # or init-stackview -- loads the hook
(gdb) stackview                    # status: views + their files + pane cmds
(gdb) stackview off | stackview on | stackview default
(gdb) stackview bt @stack @frame  # any mix of commands + builtins
```

---

## What the installers do

### `gdb-plugins` (`make gdb-plugins`)

1. apt: `gdb git python3 gcc libc6-dbg python3-six`
2. clones/updates `~/peda`, `~/Pwngdb` (scwuaptx), `~/gef` (hugsy),
   `~/pwndbg` (venv built only if missing)
3. **six fix**: replaces peda's bundled `six` 1.9.0 with the system six —
   the old one breaks on Python 3.13 (`No module named 'six.moves'`)
   (backup: `~/peda/lib/six.py.old-1.9-0`)
4. **angelheap patch**: `tracemalloc` breakpoints `_int_malloc`/`_int_free`,
   which **glibc 2.41 removed** → falls back to public `malloc`/`free`
   (backup: `angelheap.py.orig`; idempotent via `TRACE_PUBLIC` marker)
5. `~/.gdbinit` block: SyntaxWarning filter, `init-*` + `pwn` defines,
   `hook-run` (re-inits angelheap tracking on every `run`);
   `~/.gdbinit_pwndbg` → `source ~/pwndbg/gdbinit.py`
   (a gdb **command file**, *not* a symlink — see Gotchas)
6. self-test: heapinfo, parseheap, warnings, tracemalloc double-free,
   `pwn`→pwndbg `heap`, gef `heap chunks`

### `heapview` (`make heapview`)

1. apt: `tmux`
2. `~/heapview/heapview.py` (stop-hook; ONE FILE PER VIEW:
   `/tmp/gdb-view-<view>.txt`) + `~/heapview/heapview-pane.sh`
   (viewer for ONE view: `heapview-pane.sh <view>`)
   + `heapview/.bashrc_alias_gdb` → **`/etc/bash_aliases.d/.bashrc_alias_gdb`**
   (copied, **executable**; the `gdb-tmux-hv-*` view-pane aliases)
3. `~/.gdbinit` block: `init-heapview` define
4. `~/.bashrc` block: sources `/etc/bash_aliases.d/.bashrc_alias_gdb`
   (Debian bash does not source that dir by default)

### `stackview` (`make stackview`)

Same design as heapview, for the **stack** — two builtin views:

| view | file | pane |
|---|---|---|
| `@stack` (**builtin**) | `/tmp/gdb-stackview-stack.txt` | `stackview-pane.sh stack` |
| `@frame` (**builtin**) | `/tmp/gdb-stackview-frame.txt` | `stackview-pane.sh frame` |
1. apt: `tmux`
2. `~/stackview/stackview.py` (stop-hook; ONE FILE PER VIEW:
   `/tmp/gdb-stackview-<view>.txt`; `@stack` = rsp/rbp/frame-size + 32-qword
   hexdump from rsp, `@frame` = `info frame`) + `~/stackview/stackview-pane.sh`
3. `~/.gdbinit` block: `init-stackview` define (also sourced by
   `init-pwngdb` when present → `pwn` loads it)
4. `stackview/.bashrc_alias_gdb_stack` → **`/etc/bash_aliases.d/.bashrc_alias_gdb_stack`**
   (copied, **executable**; the `gdb-tmux-sv-stack` / `gdb-tmux-sv-frame` aliases)
   + `~/.bashrc` block sourcing it (`# >>> stack-tools >>>`)

### `testprograms` (`make testprograms`)

1. builds `out/heaptest` (break at **line 9** = after the mallocs) and
   `out/dblfree` (double free → tcache abort) with `gcc -g -O0`
   — into the **repo-local `out/`** (next to the Makefile), which is
   **gitignored** (`.gitignore`); `make clean` removes it

---

## Gotchas / troubleshooting

| Symptom | Explanation |
|---|---|
| `heapinfo` → "Can't find heap info" / `heapbase` → "heap not found" | **Not a bug.** The heap is created by the *first malloc* — at `main` there is none. Break *after* an allocation. |
| `p main_arena` shows `top = 0x0` | Same as above — malloc never ran. |
| `b malloc; r` stops in `rtld-malloc.h` | You hit the **dynamic loader's** malloc. Prefer `starti`, then break on source lines. |
| bare `heap` is "ambiguous" | In pwngdb it's a prefix (`heapbase`, `heapinfo`, ...); use `heapinfo`. GEF wants `heap chunks`. Only pwndbg has plain `heap`. |
| `tracemalloc` prints "Can't create Breakpoint" | Fixed by the angelheap patch (see above). Re-run `make gdb-plugins`. |
| GEF output looks garbled when grepping | GEF wraps ANSI colors in `\x01`/`\x02` markers; strip with `sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x01//g' -e 's/\x02//g'`. |
| `libc6-dbg:i386` not found | Only for 32-bit targets: `dpkg --add-architecture i386 && apt update && apt install libc6-dbg:i386`. |
| `~/.gdbinit` looks duplicated | Old monolithic setup? It's auto-migrated: backup at `~/.gdbinit.legacy`, then rewritten from marker blocks. |
| Two gdb sessions fight over the panes | Both write the same `/tmp/gdb-view-*.txt` — one pane set per gdb session. |
| heap panes stay "(waiting for first stop)" after loading other plugins | gdb runs ALL sourced `.py` files in **one shared Python namespace** — a plugin sourced later (e.g. stackview after heapview) redefines module-level globals of the earlier one. Both view hooks therefore keep ALL state inside classes (`self.*`), no module-level variables — fixed & guarded by an installer check ("heapinfo fresh under init-pwngdb"). |

### Uninstall

Each feature leaves a clean trace (idempotent blocks, backups):

```bash
sed -i '/^# >>> heapview >>>/,/^# <<< heapview <<</d; /^# >>> stackview >>>/,/^# <<< stackview <<</d; /^# >>> gdb-plugins >>>/,/^# <<< gdb-plugins <<</d' ~/.gdbinit
sed -i '/^# >>> heap-tools >>>/,/^# <<< heap-tools <<</d; /^# >>> stack-tools >>>/,/^# <<< stack-tools <<</d' ~/.bashrc
rm -f /etc/bash_aliases.d/.bashrc_alias_gdb /etc/bash_aliases.d/.bashrc_alias_gdb_stack   # needs root
make clean                      # removes out/
rm -rf ~/heapview ~/stackview ~/peda ~/Pwngdb ~/gef ~/pwndbg ~/.gdbinit_pwndbg
```

---

## Repo layout

```
heap-tools/
├── Makefile               # make / make all | make <feature> | make clean
├── .gitignore             # ignores out/, __pycache__/
├── README.md              # this file
├── AGENTS.md              # agent/worklog docs (fixes, design decisions)
├── gdb-plugins/install.sh
├── heapview/{install.sh,heapview.py,heapview-pane.sh,.bashrc_alias_gdb}
├── stackview/{install.sh,stackview.py,stackview-pane.sh,.bashrc_alias_gdb_stack}
├── testprograms/{install.sh,heaptest.c,dblfree.c}
└── out/                    # build artifacts (created by make, gitignored)
```

`make all` runs **heapview → stackview → gdb-plugins → testprograms**
(views first so that `pwn`/`init-pwngdb` embed their hooks). Tested on
Debian 13 (trixie), gdb 16.3 / Python 3.13.5 / glibc 2.41.