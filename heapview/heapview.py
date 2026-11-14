# heapview.py -- auto-refresh heap views (one FILE per view) for pwngdb/angelheap
#
# On EVERY stop (break / step / next / signal) this hook writes EACH view to
# its OWN file, so you can dedicate one tmux pane per view:
#
#   pane A (gdb):   gdb -q out/heaptest             (pwn/init-pwngdb/init-heapview loads this file)
#   pane B (view):  tmux split-window -h 'bash ~/heapview/heapview-pane.sh heapinfo'
#   pane C (view):  tmux split-window -h 'bash ~/heapview/heapview-pane.sh arena'
#
# Views (list) are refreshed together on every stop; each lands in its own file:
#   <view> = any gdb/pwngdb command  -> /tmp/gdb-view-<command>.txt
#            builtin "@arena"        -> /tmp/gdb-view-arena.txt
#            (file name: view name, "@"/spaces -> stripped/underscored)
# Each view file contains: a stop header (function/file:line/pc/pid) + the view.
# Panes SELF-REGISTER: they touch /tmp/gdb-view-req/<view> every second; every
# requested view is written on every stop (requests expire ~5s after the pane
# closes). Bare names map to builtins (arena -> @arena).
#
# Commands:
#   heapview                       -> status (views + their files)
#   heapview on / off              -> enable / disable writing
#   heapview default               -> reset views to [heapinfo, @arena]
#   heapview <view...>             -> set views, e.g. heapview heapinfo parseheap @arena
#
# NOTE on design: gdb executes ALL sourced .py files in ONE shared namespace
# (peda/pwngdb/stackview/... all live there too!). Everything here therefore
# lives inside classes with `self.*` state -- NO module-level variables except
# the uniquely-named instances (heapview_hook). This keeps heapview immune to
# globals being redefined by other plugins loaded after it.
#
from __future__ import print_function
import gdb
import os
import re
import time


class HeapViewHook(object):
    VIEW_PREFIX = "/tmp/gdb-view-"
    REQ_DIR = "/tmp/gdb-view-req"     # panes touch <view> here every second
    REQ_TTL = 5                      # seconds a request survives without its pane
    MASK64 = (1 << 64) - 1
    DEFAULT_VIEWS = ["heapinfo", "@arena"]
    # bare pane names (stripped) -> builtin view names
    BUILTIN_ALIASES = {"arena": "@arena"}

    def __init__(self):
        self.enabled = True
        self.views = list(self.DEFAULT_VIEWS)
        self.files = []
        gdb.events.stop.connect(self.refresh)      # every break/step/signal stop
        gdb.events.exited.connect(self.on_exit)

    # --- helpers ----------------------------------------------------------
    def _write(self, path, text, mode="w"):
        try:
            with open(path, mode) as f:
                f.write(text)
        except OSError as e:
            gdb.write("heapview: cannot write %s: %s\n" % (path, e))

    def _u(self, val):  # gdb value / int -> unsigned int (64-bit truncation)
        try:
            return int(val) & self.MASK64
        except Exception:
            return 0

    def _read_u64(self, addr):
        return self._u(gdb.parse_and_eval("*(unsigned long*)%d" % addr))

    def view_file(self, view):
        name = view.lstrip("@").replace(" ", "_")
        name = re.sub(r"[^A-Za-z0-9_-]", "_", name)
        return "%s%s.txt" % (self.VIEW_PREFIX, name)

    # --- view: stop header --------------------------------------------------
    def fmt_stop_header(self):
        try:
            frame = gdb.selected_frame()
            name = frame.name() or "??"
            try:
                sal = frame.find_sal()
                # note: gdb.Symtab.filename is a PROPERTY in gdb 16 (str), not a method
                loc = "%s:%d" % (sal.symtab.filename, sal.line) if sal.symtab else "??"
            except Exception:
                loc = "??:?"
            pc = self._u(frame.pc())
            pid = gdb.selected_inferior().pid
            return "stop: %s at %s  (pc 0x%x, pid %d)" % (name, loc, pc, pid)
        except Exception:
            return "stop: (no frame)"

    # --- view: @arena (builtin) ----------------------------------------------
    def fmt_arena(self):
        try:
            addr = self._u(gdb.parse_and_eval("&main_arena"))
            arena = gdb.parse_and_eval("main_arena")
        except Exception as e:
            return "(main_arena unavailable: %s\nneeds a running process + libc debug symbols)" % e

        def field(name):
            try:
                return arena[name]
            except Exception:
                return None

        lines = ["arena            : 0x%x (main_arena)" % addr]
        for f in ("mutex", "flags", "have_fastchunks"):
            v = field(f)
            if v is not None:
                lines.append("%-16s : 0x%x" % (f, self._u(v)))
        top = self._u(field("top"))
        if top:
            try:
                tsize = self._read_u64(top + 8) & ~0xf  # chunk size, flags masked
                lines.append("%-16s : 0x%x (size 0x%x)" % ("top", top, tsize))
            except Exception:
                lines.append("%-16s : 0x%x" % ("top", top))
        else:
            lines.append("%-16s : (none -- no malloc yet)" % "top")
        lines.append("%-16s : 0x%x" % ("last_remainder", self._u(field("last_remainder"))))
        for f in ("next", "next_free"):
            v = self._u(field(f))
            suffix = " (self)" if f == "next" and v == addr else ""
            lines.append("%-16s : 0x%x%s" % (f, v, suffix))
        for f in ("attached_threads", "system_mem", "max_system_mem"):
            v = field(f)
            if v is not None:
                lines.append("%-16s : 0x%x" % (f, self._u(v)))
        fb = field("fastbinsY")
        if fb is not None:
            entries = []
            try:
                for i in range(10):
                    p = self._u(fb[i])
                    if p:
                        entries.append("[idx %d sz 0x%x] 0x%x" % (i, 0x20 + 0x10 * i, p))
            except Exception:
                entries = []
            lines.append("%-16s : %s" % ("fastbinsY", ", ".join(entries) if entries else "empty"))
        bm = field("binmap")
        if bm is not None:
            try:
                words = ", ".join("0x%x" % self._u(bm[i]) for i in range(4))
                lines.append("%-16s : %s" % ("binmap", words))
            except Exception:
                pass
        return "\n".join(lines)

    # --- requested views (self-registering panes) ------------------------------
    def requested_views(self):
        """Views requested by live panes (they touch REQ_DIR/<view> every second).
        Bare names are mapped to builtins (arena -> @arena). Expired requests
        (pane closed/killed) are unlinked and dropped."""
        views = []
        now = time.time()
        try:
            names = os.listdir(self.REQ_DIR)
        except OSError:
            return views
        for name in names:
            path = os.path.join(self.REQ_DIR, name)
            try:
                if now - os.path.getmtime(path) < self.REQ_TTL:
                    views.append(self.BUILTIN_ALIASES.get(name, name))
                else:
                    os.unlink(path)
            except OSError:
                pass
        return views

    # --- refresh: one file per view (defaults + pane requests) ------------------
    def refresh(self, *events):
        if not self.enabled:
            return
        header = self.fmt_stop_header()
        all_views = list(self.views)
        for v in self.requested_views():
            if v not in all_views:
                all_views.append(v)
        new_files = []
        for view in all_views:
            path = self.view_file(view)
            new_files.append(path)
            if view == "@arena":
                body = self.fmt_arena()
            else:
                try:
                    body = gdb.execute(view, to_string=True).rstrip()
                except gdb.error as e:
                    body = "'%s' failed: %s\n(load the plugin first: init-pwngdb)" % (view, e)
            self._write(path, "%s\n\n%s\n" % (header, body))
        # remove stale files from a previous refresh (only ones we wrote)
        for old in self.files:
            if old not in new_files:
                try:
                    os.unlink(old)
                except OSError:
                    pass
        self.files = new_files

    def on_exit(self, *events):
        # append (not overwrite): keep the last heap state visible in the pane
        for path in self.files:
            self._write(path, "\n(inferior exited)\n", mode="a")


class HeapViewCmd(gdb.Command):
    """heapview [on|off|default|view...] -- control the auto heap-view files"""

    def __init__(self, hook):
        self.hook = hook
        super(HeapViewCmd, self).__init__("heapview", gdb.COMMAND_USER)

    def invoke(self, arg, from_tty):
        hook = self.hook
        args = arg.split()
        if not args:
            print("heapview: %s | views: %s" % ("on" if hook.enabled else "off",
                                                " ".join(hook.views)))
            print("  (panes self-register their view via %s/<view> -- no setup needed)" % hook.REQ_DIR)
            all_views = list(hook.views) + [v for v in hook.requested_views() if v not in hook.views]
            for v in all_views:
                print("  %-12s -> %s  (pane: bash ~/heapview/heapview-pane.sh %s)"
                      % (v, hook.view_file(v), v.lstrip("@").replace(" ", "_")))
            print("  set: heapview <view...>  ('@arena' = builtin arena status; default = heapinfo @arena)")
            return
        if args[0] == "on":
            hook.enabled = True
        elif args[0] == "off":
            hook.enabled = False
            for path in hook.files:
                hook._write(path, "(heapview off)\n")
            return
        elif args[0] == "default":
            hook.views = list(hook.DEFAULT_VIEWS)
            hook.enabled = True
        else:  # view list (bare names map to builtins)
            hook.views = [hook.BUILTIN_ALIASES.get(a, a) for a in args]
            hook.enabled = True
        hook.refresh()


# uniquely-named instances (gdb shares ONE namespace across all sourced .py files!)
heapview_hook = HeapViewHook()
for _v in HeapViewHook.DEFAULT_VIEWS:
    heapview_hook._write(heapview_hook.view_file(_v), "(waiting for first stop)\n")
HeapViewCmd(heapview_hook)
gdb.write("heapview: on -- every stop writes '%s*' -- views: %s\n"
          % (HeapViewHook.VIEW_PREFIX, " ".join(HeapViewHook.DEFAULT_VIEWS)))