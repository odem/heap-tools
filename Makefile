# heap-tools -- gdb heap- & stack-debugging toolkit (per-feature installers + Makefile)
#
# Each feature lives in its own folder with a self-contained install.sh.
#   make                (or: make all)  -- install everything
#   make gdb-plugins                    -- peda + Pwngdb/angelheap + gef + pwndbg (+fixes)
#   make heapview                       -- auto-refresh heap panes (tmux)
#   make stackview                      -- auto-refresh stack panes (tmux)
#   make testprograms                   -- build test binaries (heaptest, dblfree) into out/
#
# Installers are idempotent; every installer self-verifies (PASS/FAIL) and
# exits non-zero on failure. Install order for `all`: heapview -> stackview
# -> gdb-plugins -> testprograms (gdb-plugins embeds init-heapview /
# init-stackview into `pwn`/init-pwngdb if present).

.NOTPARALLEL:
.PHONY: all gdb-plugins heapview stackview testprograms clean

all: heapview stackview gdb-plugins testprograms

clean:
	rm -rf out

heapview:
	bash heapview/install.sh

stackview:
	bash stackview/install.sh

gdb-plugins:
	bash gdb-plugins/install.sh

testprograms:
	bash testprograms/install.sh