# stackview.py -- auto-refresh stack views (one FILE per view) -- mirrors heapview
#
# On EVERY stop (break / step / next / signal) this hook writes EACH view to
# its OWN file, so you can dedicate one tmux pane per view:
#
#   pane A (gdb):    gdb -q out/heaptest            (pwn/init-pwngdb/init-stackview loads this)
#   pane B (view):   tmux split-window -h 'bash ~/stackview/stackview-pane.sh stack'
#   pane C (view):   tmux split-window -h 'bash ~/stackview/stackview-pane.sh frame'
#
# Views (refreshed together on every stop; each into its own file):
#   "@stack"  BUILTIN -> /tmp/gdb-stackview-stack.txt : RAW stack memory
#             (rsp, rbp, frame size + 32 qwords hexdump from rsp)
#   "@frame"  BUILTIN -> /tmp/gdb-stackview-frame.txt : CURRENT stackframe
#             (gdb `info frame`: level, rip, rbp/rsp, saved regs, caller...)
#   any gdb/pwngdb command -> /tmp/gdb-stackview-<cmd>.txt (e.g. `bt`)
#
# Panes SELF-REGISTER: they touch /tmp/gdb-stackview-req/<view> every second;
# every requested view is written on every stop (request expires ~5s after the
# pane closes). Bare names map to builtins: stack -> @stack, frame -> @frame.
#
# Commands:
#   stackview                    -> status (views + their files)
#   stackview on / off           -> enable / disable writing
#   stackview default            -> reset views to [@stack, @frame]
#   stackview <view...>          -> set views, e.g. stackview bt @stack @frame
#
# NOTE on design: gdb executes ALL sourced .py files in ONE shared namespace
# (peda/pwngdb/heapview/... all live there too!). Everything here therefore
# lives inside classes with `self.*` state -- NO module-level variables except
# the uniquely-named instances (stackview_hook). This keeps stackview immune to
# globals being redefined by other plugins loaded after it.
#
from __future__ import print_function
import gdb
import os
import re
import time


class StackViewHook(object):
    VIEW_PREFIX = "/tmp/gdb-stackview-"
    REQ_DIR = "/tmp/gdb-stackview-req"     # panes touch <view> here every second
    REQ_TTL = 5                           # seconds a request survives without its pane
    MASK64 = (1 << 64) - 1
    DEFAULT_VIEWS = ["@stack", "@frame"]
    # bare pane names (stripped) -> builtin view names
    BUILTIN_ALIASES = {"stack": "@stack", "frame": "@frame"}

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
            gdb.write("stackview: cannot write %s: %s\n" % (path, e))

    def _u(self, val):
        try:
            return int(val) & self.MASK64
        except Exception:
            return 0

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

    # --- view: @stack (builtin: raw stack memory) -------------------------------
    def fmt_stack(self):
        try:
            rsp = self._u(gdb.parse_and_eval("$rsp"))
            rbp = self._u(gdb.parse_and_eval("$rbp"))
        except Exception as e:
            return "(registers unavailable: %s\nneeds a running process)" % e
        lines = ["rsp              : 0x%x" % rsp,
                 "rbp              : 0x%x" % rbp,
                 "frame size (rbp-rsp): 0x%x" % ((rbp - rsp) & self.MASK64),
                 "",
                 "-- 16 qwords from rsp --"]
        try:
            lines.append(gdb.execute("x/16gx $rsp", to_string=True).rstrip())
        except gdb.error as e:
            lines.append("(x/16gx failed: %s)" % e)
        return "\n".join(lines)

    # --- view: @frame (builtin: current stackframe) -----------------------------
    def fmt_frame(self):
        try:
            return gdb.execute("info frame", to_string=True).rstrip()
        except gdb.error as e:
            return "(info frame failed: %s\nneeds a running process)" % e

    # --- requested views (self-registering panes) ------------------------------
    def requested_views(self):
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
            if view == "@stack":
                body = self.fmt_stack()
            elif view == "@frame":
                body = self.fmt_frame()
            else:
                try:
                    body = gdb.execute(view, to_string=True).rstrip()
                except gdb.error as e:
                    body = "'%s' failed: %s" % (view, e)
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
        # append (not overwrite): keep the last state visible in each pane
        for path in self.files:
            self._write(path, "\n(inferior exited)\n", mode="a")


class StackViewCmd(gdb.Command):
    """stackview [on|off|default|view...] -- control the auto stack-view files"""

    def __init__(self, hook):
        self.hook = hook
        super(StackViewCmd, self).__init__("stackview", gdb.COMMAND_USER)

    def invoke(self, arg, from_tty):
        hook = self.hook
        args = arg.split()
        if not args:
            print("stackview: %s | views: %s" % ("on" if hook.enabled else "off",
                                                 " ".join(hook.views)))
            print("  (panes self-register their view via %s/<view> -- no setup needed)" % hook.REQ_DIR)
            all_views = list(hook.views) + [v for v in hook.requested_views() if v not in hook.views]
            for v in all_views:
                print("  %-8s -> %s  (pane: bash ~/stackview/stackview-pane.sh %s)"
                      % (v, hook.view_file(v), v.lstrip("@")))
            print("  set: stackview <view...>  (builtins: @stack raw memory, @frame current frame; default = @stack @frame)")
            return
        if args[0] == "on":
            hook.enabled = True
        elif args[0] == "off":
            hook.enabled = False
            for path in hook.files:
                hook._write(path, "(stackview off)\n")
            return
        elif args[0] == "default":
            hook.views = list(hook.DEFAULT_VIEWS)
            hook.enabled = True
        else:  # view list (bare names map to builtins)
            hook.views = [hook.BUILTIN_ALIASES.get(a, a) for a in args]
            hook.enabled = True
        hook.refresh()


# uniquely-named instances (gdb shares ONE namespace across all sourced .py files!)
stackview_hook = StackViewHook()
for _v in StackViewHook.DEFAULT_VIEWS:
    stackview_hook._write(stackview_hook.view_file(_v), "(waiting for first stop)\n")
StackViewCmd(stackview_hook)
gdb.write("stackview: on -- every stop writes '%s*' -- views: %s\n"
          % (StackViewHook.VIEW_PREFIX, " ".join(StackViewHook.DEFAULT_VIEWS)))
