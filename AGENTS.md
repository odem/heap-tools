# AGENTS.md — heap-tools

Per-feature installers + Makefile for the gdb heap-debugging toolkit
(peda + Pwngdb/angelheap + gef + pwndbg + auto heap-view pane).
Deployed/tested on the local **testvm** (`ssh root@10.10.123.222`, Debian 13
trixie, gdb 16.3/Python 3.13, glibc 2.41); should work on any Debian 13.

## Repo layout

```
heap-tools/
├── Makefile               # make / make all | make <feature> | make clean
├── .gitignore             # ignores out/, __pycache__/
├── AGENTS.md              # this file
├── README.md              # user-facing docs
├── gdb-plugins/
│   └── install.sh         # apt, clones, six fix, angelheap patch, .gdbinit mux
├── heapview/
│   ├── install.sh         # tmux, files -> ~/heapview, init-heapview + gdb-tmux-hv-* aliases
│   ├── .bashrc_alias_gdb  # gdb-tmux-hv-* aliases -> installed to /etc/bash_aliases.d/
│   ├── heapview.py        # gdb stop-hook -> /tmp/gdb-view-<view>.txt (1 per view)
│   └── heapview-pane.sh   # dedicated tmux pane (per view: <view> arg)
├── stackview/
│   ├── install.sh         # tmux, files -> ~/stackview, init-stackview + gdb-tmux-sv-* aliases
│   ├── .bashrc_alias_gdb_stack  # gdb-tmux-sv-* aliases -> installed to /etc/bash_aliases.d/
│   ├── stackview.py       # gdb stop-hook -> /tmp/gdb-stackview-<view>.txt (1 per view)
│   └── stackview-pane.sh  # dedicated tmux pane (per view: <view> arg)
├── testprograms/
│   ├── install.sh         # gcc build -> <repo>/out (gitignored)
│   ├── heaptest.c         # break at line 9 = after the mallocs
│   └── dblfree.c          # double free -> tcache abort
└── out/                    # build artifacts (gitignored, make clean)
```

## Make targets

```
make            # = make all: heapview -> stackview -> gdb-plugins -> testprograms (ordered, .NOTPARALLEL)
make heapview
make stackview
make gdb-plugins
make testprograms
make clean       # rm -rf out (build artifacts)
```

Every installer: **idempotent** (safe to re-run), **self-verifying** (PASS/FAIL,
exits non-zero on failure). Expected results: heapview **10/0**,
stackview **9/0**, gdb-plugins **15/0**, testprograms **3/0**.

`make all` order matters: heapview + stackview first, so gdb-plugins embeds
their hooks into `pwn`/`init-pwngdb` when present.

## What each feature installs

### gdb-plugins
- apt: `gdb git python3 gcc libc6-dbg python3-six`
- sources: `~/peda` (longld/peda), `~/Pwngdb` (scwuaptx/Pwngdb → pwngdb.py +
  angelheap), `~/gef` (hugsy/gef), `~/pwndbg` (pwndbg/pwndbg; venv built only
  if `.venv` missing)
- `~/.gdbinit_pwndbg` → `source ~/pwndbg/gdbinit.py`
  ⚠ gdb **command file**, NOT a symlink — `source` on `.py` executes it as Python
- `~/.gdbinit` marker block `# >>> gdb-plugins >>>`: SyntaxWarning filter,
  `init-peda`, `init-pwngdb`, `init-pwndbg`*, `init-gef`*, `pwn`*
  (`init-pwndbg`+`init-pwngdb`+`init-heapview` if present), `hook-run`
  (*only if the respective plugin is installed)
- self-check with /tmp binaries: heapinfo, parseheap, SyntaxWarnings=0,
  tracemalloc double-free, pwn→pwndbg `heap`, gef `heap chunks`

### heapview
- apt: `tmux`
- `~/heapview/heapview.py` + `~/heapview/heapview-pane.sh`
- `~/.gdbinit` marker block `# >>> heapview >>>`: `init-heapview` define
- `~/.bashrc` marker block `# >>> heap-tools >>>`: sources
  `/etc/bash_aliases.d/.bashrc_alias_gdb` — repo file `heapview/.bashrc_alias_gdb`
  copied there by the installer (chmod +x; Debian bash does NOT source that
  dir by default, hence the explicit source block); contains the
  `gdb-tmux-hv-*` (tmux split-window; INSIDE tmux only) and `gdb-hv-*`
  (run the pane DIRECTLY in the current terminal, no tmux) view-pane aliases
  (documented in README "Bash aliases")
- architecture: `gdb.events.stop` (EVERY break/step/signal) refreshes ALL
  **views**, **ONE FILE PER VIEW**: `/tmp/gdb-view-<view>.txt`
  (view name with `@`/spaces stripped/underscored; e.g. `@arena` →
  `gdb-view-arena.txt`, `info registers` → `gdb-view-info_registers.txt`);
  `gdb.events.exited` **appends** `(inferior exited)` to each view file
  (append, not overwrite — keeps last heap state visible; overwriting broke
  the installer's own grep); stale files from a previous view set are
  unlinked on refresh
- each view file = **stop header** (function/file:line/pc/pid) + view output;
  views: any gdb/pwngdb command + builtin `@arena` (formatted `main_arena`
  status: address, mutex, flags, have_fastchunks, top + size,
  last_remainder, next/next_free, attached_threads, system_mem,
  max_system_mem, fastbinsY, binmap — read via `gdb.parse_and_eval` on the
  `malloc_state` struct, needs libc6-dbg)
- default views: `[heapinfo, @arena]`
- gdb TUI **cannot** do custom windows: `tui new-layout x heapinfo 1` →
  `Unknown window "heapinfo"` (verified gdb 16.3) — hence file+pane design
- pane (ONE PER VIEW): `tmux split-window -h 'bash ~/heapview/heapview-pane.sh heapinfo'`
  (or `... arena`, `... parseheap`, ...; clear + cat view file, 1s loop)
  **self-registering**: panes touch `/tmp/gdb-view-req/<view>` every second;
  the hook writes defaults + every requested view on each stop (requests
  expire ~5s after the pane closes) — no `heapview <views>` setup needed;
  bare request names map to builtins via `BUILTIN_ALIASES`
  (heapview: `arena` → `@arena`; stackview: `stack` → `@stack`, `frame` → `@frame`)
- gdb-side: `heapview` (status: views + files + pane cmds), `heapview off/on`,
  `heapview default` (reset to [heapinfo, @arena]),
  `heapview <views...>` (e.g. `heapview heapinfo parseheap @arena`)
- note: two gdb sessions share the `/tmp/gdb-view-*.txt` files

### stackview
- mirrors heapview for the **stack** (same architecture: stop-hook → one file
  per view → self-registering panes; prefix `/tmp/gdb-stackview-`,
  req dir `/tmp/gdb-stackview-req`)
- builtin views:
  - `@stack` → `gdb-stackview-stack.txt`: **raw stack memory** — rsp, rbp,
    frame size (rbp-rsp) + `x/32gx $rsp` hexdump
  - `@frame` → `gdb-stackview-frame.txt`: **current stackframe** —
    `info frame` (level, frame address, rip/rbp/rsp, saved regs, caller, ...)
  - any gdb command works as a view too (e.g. `bt`)
- default views: `[@stack, @frame]`; gdb command: `stackview`
  (`stackview off/on/default/<views...>` — same semantics as heapview)
- installed by `stackview/install.sh`: apt `tmux`, files → `~/stackview/`,
  `~/.gdbinit` marker block `# >>> stackview >>>` (`init-stackview` define),
  aliases repo file `stackview/.bashrc_alias_gdb_stack` →
  `/etc/bash_aliases.d/.bashrc_alias_gdb_stack` (chmod +x) + `~/.bashrc`
  block `# >>> stack-tools >>>` sourcing it
  (`gdb-tmux-sv-*` tmux + `gdb-sv-*` direct-terminal aliases)
- `gdb-plugins/install.sh`'s `init-pwngdb` sources `~/stackview/stackview.py`
  too (when present), so `pwn` loads it
- **shared-namespace gotcha** (found the hard way): gdb executes ALL sourced
  `.py` files in ONE shared Python namespace — stackview sourced after
  heapview redefined heapview's module globals (`_state`/`REQ_DIR`/`refresh`)
  → heapview's stop handler wrote STACKVIEW files, heap files stayed at the
  load-time placeholder. Fix: both hooks keep ALL state in classes
  (`HeapViewHook`/`StackViewHook`, `self.*`), only uniquely-named instances
  at module level (`heapview_hook`/`stackview_hook`). heapview's installer
  checks for regressions ("heapinfo fresh under init-pwngdb").

### testprograms
- builds `out/heaptest` (break at **line 9** = after the mallocs) and
  `out/dblfree` (double free → tcache abort) into the **repo-local `out/`**
  (gitignored via `.gitignore`); sources stay in `testprograms/`
- `make clean` removes `out/`

## ~/.gdbinit management (marker blocks)

Both features write **their own** block, delimited by
`# >>> <name> >>>` … `# <<< <name> <<<`; re-running replaces the block
(sed range-delete + append). Blocks don't touch each other → order-independent.

**Migration**: if `~/.gdbinit` has no `# >>>` markers AND carries the legacy
header `# ~/.gdbinit -- generated by install_gdb.bash` (our old monolithic
installer), it is backed up to `~/.gdbinit.legacy` and **reset**; custom
files are never touched (only appended to).

## Key fixes (why stock plugins were broken)

1. **peda six crash** — `No module named 'six.moves'`: `peda.py:26`
   `sys.path.insert(0, .../lib)` shadows system six with bundled six 1.9.0,
   which breaks on Python 3.13 (gdb 16). Fix: system six 1.17 →
   `~/peda/lib/six.py` (backup `six.py.old-1.9-0`), delete stale `__pycache__`.
2. **angelheap tracemalloc** — "Can't create Breakpoint": glibc 2.41 removed
   `_int_malloc`/`_int_free`. Patch (backup `.orig`, idempotent via
   `TRACE_PUBLIC` marker): probe `_int_malloc` via `gdb.parse_and_eval`; if
   gone, breakpoint public `malloc`/`free`, args from `$rdi` (not `$rsi`),
   and `free`'s rdi **is** the user pointer (no `+0x10` adjust).
3. **GEF** — was a 0-byte `~/.gdbinit-gef.py` stub → `init-gef` sourced
   nothing. Fix: clone hugsy/gef, `init-gef` → `source ~/gef/gef.py`.
4. **`p`/`.py` sourcing** — `.py` files given to `source` are executed as
   Python; gdb-command text in a `.py` name dies (`NameError: 'source'`).

## Verified usage (VM)

**Convention: the debugged binary lives in repo-local `out/`** (created by
`make`, gitignored; `make clean` wipes). Test binaries: `out/heaptest`,
`out/dblfree` — user targets go there too (`out/<name>`), run gdb from the
repo root. All examples below assume that.

```
gdb -q out/heaptest           # from the repo root (binaries in out/, gitignored)
(gdb) pwn                 # default combo: pwndbg + pwngdb (+ heapview)
(gdb) starti              # stop at loader entry (libc not mapped yet)
(gdb) b heaptest.c:9      # break AFTER some malloc()s ran
(gdb) c
(gdb) heapinfo | parseheap | heapbase | chunkptr <user_ptr>   # pwngdb
(gdb) heap | vis | bins | arenas                             # pwndbg
(gdb) heap chunks | heap bins | heap arenas                   # gef (subcmds!)
(gdb) b main && c && tracemalloc on && c    # trace malloc/free, flag double frees
(gdb) heapview @arena                     # ONLY arena view (file gdb-view-arena.txt)
(ggdb) heapview heapinfo parseheap @arena     # three views (three files/panes)
# ONE pane PER view (auto-refresh each stop):
tmux split-window -h 'bash ~/heapview/heapview-pane.sh heapinfo'
tmux split-window -h 'bash ~/heapview/heapview-pane.sh arena'
# aliases:  inside tmux: gdb-tmux-hv-heapinfo/-arena/-parseheap, gdb-tmux-sv-stack/-frame
#           direct (no tmux): gdb-hv-heapinfo/-arena/-parseheap, gdb-sv-stack/-frame
# stack views:  bash ~/stackview/stackview-pane.sh stack   # raw memory from rsp
#               bash ~/stackview/stackview-pane.sh frame   # current stackframe
```

## Gotchas

- **Heap exists only after the first malloc** — `main_arena.top == 0`, no
  `[heap]` mapping at `main`: `heapinfo`/`heapbase` correctly say "can't find".
- `b malloc` before `r` stops in the **dynamic loader's** malloc
  (`rtld-malloc.h`, "Breakpoint 1.22", missing-source warning is normal).
- pwngdb resolves `__libc_version`/`main_arena` from the **running** libc
  (full symbols via `libc6-dbg`, not in `.dynsym`).
- bare `heap` is ambiguous in pwngdb (`heapbase`/`heapinfo`…); GEF wants
  subcommands.
- GEF output wraps ANSI in readline `\x01`/`\x02` markers — strip
  (`sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\x01//g' -e 's/\x02//g'`)
  before grepping. Shell gotcha: `$(cmd || true | strip)` binds the pipe to
  `true` — capture, then strip in a second step.
- `libc6-dbg:i386` needs `dpkg --add-architecture i386` (32-bit targets only).
- pwndbg re-syncs its `.venv` from `uv.lock` on first load after pulls
  ("Detected outdated Pwndbg dependencies") — one-time, expected.
- peda py2 regexes emit `SyntaxWarning` on py3.13 — filtered via the
  gdb-plugins block.

## Deploy to the testvm

```
scp -r heap-tools root@10.10.123.222:/root/
ssh root@10.10.123.222
cd /root/heap-tools && make        # all features, ordered
# or: make gdb-plugins | make heapview | make testprograms
```

## Workflow for changes

1. Edit locally in `heap-tools/` (`bash -n`, `python -m ast` for payloads).
2. `scp -r heap-tools root@10.10.123.222:/root/`
3. Run `make` on the VM — **all features must pass** (4/0, 15/0, 3/0);
   re-run to confirm idempotency (same results, no dupes in `~/.gdbinit`).
4. Update this AGENTS.md if layout/fixes/paths changed.