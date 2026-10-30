#!/usr/bin/env python3
"""mem_reaper.py -- force-stop your own macOS processes that eat too much memory.

Memory is read from `top`'s MEM column, which is the physical footprint -- the
same number Activity Monitor's "Memory" column shows. `ps` RSS is NOT usable
for this: macOS compresses idle pages, so a process holding 1.5 GB reports
~1 MB of RSS and would never be noticed.

Nothing is killed without you confirming it, either at the terminal or with a
macOS modal dialog (--service mode, which is what the LaunchAgent runs).

  python3 mem_reaper.py                       # dry run: offenders + your top 15
  python3 mem_reaper.py --kill                # confirm each kill in the terminal
  python3 mem_reaper.py --service             # background mode: modal dialogs, loops forever
  python3 mem_reaper.py --confirm-gui         # one-shot scan, modal dialog per offender
  python3 mem_reaper.py --stop-pid 1234       # stop one process you already confirmed
                                              # elsewhere (the toolshed console)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

UNIT = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}

# Never touched regardless of memory: these log you out, take down the display,
# or wedge auth and the pasteboard.
PROTECTED_NAMES = {
    "launchd", "loginwindow", "WindowServer", "Dock", "Finder", "SystemUIServer",
    "ControlCenter", "NotificationCenter", "Spotlight", "WallpaperAgent",
    "cfprefsd", "distnoted", "usernoted", "tccd", "trustd", "securityd",
    "keychainaccessd", "kcd", "kdc", "launchservicesd", "coreservicesd", "lsd",
    "containermanagerd", "runningboardd", "UserEventAgent", "universalaccessd",
    "accessibilityd", "pboard", "pasteboardd", "mDNSResponder", "opendirectoryd",
    "syspolicyd", "taskgated", "amfid", "kernelmanagerd", "installd",
    "softwareupdated", "perfd", "ReportCrash", "mem_reaper.py",
}
PROTECTED_PATH_PREFIXES = (
    "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/private/var/db/",
    "/Library/Apple/",
)

# Process names and paths are passed to osascript as argv and never interpolated
# into the script text -- a process called `do shell script "rm -rf ~"` must not
# become script source.
#
# A native NSAlert rather than AppleScript's `display dialog`, because that one
# cannot be re-ticked: its static text refuses every write System Events offers,
# so `giving up after 45` freezes at "in 45s" for the whole wait. Here the timer
# rewrites the message once a second, and is registered for the modal run-loop
# mode -- in the default mode it would never fire while the alert is up.
#
# argv: title, head, seconds, buttons (|-joined, first is the safe default),
#       marker naming the field to rewrite, template holding %d for the seconds.
DIALOG_JS = r'''
ObjC.import("AppKit");

function rewriteFields(view, marker, text) {
  if (view.isKindOfClass($.NSTextField)) {
    if (view.stringValue.js.indexOf(marker) >= 0) view.setStringValue($(text));
  }
  var subs = view.subviews;
  for (var i = 0; i < subs.count; i++) rewriteFields(subs.objectAtIndex(i), marker, text);
}

function run(argv) {
  var head = argv[1];
  var total = parseInt(argv[2], 10);
  var buttons = argv[3].split("|");
  var marker = argv[4];
  var template = argv[5];
  var app = $.NSApplication.sharedApplication;
  app.setActivationPolicy(1);
  app.activateIgnoringOtherApps(true);

  var alert = $.NSAlert.alloc.init;
  alert.setIcon($.NSImage.imageNamed("NSCaution"));
  alert.setMessageText(argv[0]);
  alert.setInformativeText(head + template.replace("%d", String(total)));
  for (var b = 0; b < buttons.length; b++) alert.addButtonWithTitle(buttons[b]);

  var remain = total;
  var timedOut = false;
  var timer = $.NSTimer.scheduledTimerWithTimeIntervalRepeatsBlock(1.0, true, function (t) {
    remain = remain - 1;
    if (remain <= 0) {
      timedOut = true;
      timer.invalidate;
      app.stopModal;
      return;
    }
    var win = alert.window;
    if (!win.isNil()) rewriteFields(win.contentView, marker, head + template.replace("%d", String(remain)));
  });
  $.NSRunLoop.currentRunLoop.addTimerForMode(timer, $.NSModalPanelRunLoopMode);

  var response = alert.runModal;
  timer.invalidate;
  if (timedOut) return "TIMEOUT";
  var index = response - 1000;
  // Escape and any unmapped reply land on the safe default, never on a kill.
  if (index < 0 || index >= buttons.length) return "BUTTON:" + buttons[0];
  return "BUTTON:" + buttons[index];
}
'''


class StopRequested(Exception):
    """Raised from a signal handler so Ctrl-C and `kill` both exit cleanly."""


def install_stop_handlers() -> None:
    # A backgrounded job can inherit SIGINT as SIG_IGN, which silently makes
    # Ctrl-C a no-op; installing over it restores the ability to stop watching.
    def handler(signum, frame):
        raise StopRequested()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, handler)
        except (OSError, ValueError):
            pass

    # so `mem_reaper.py | head` exits quietly instead of dumping a BrokenPipeError
    try:
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    except (OSError, ValueError, AttributeError):
        pass


def human(nbytes: float) -> str:
    for label, mult in (("TB", UNIT["T"]), ("GB", UNIT["G"]), ("MB", UNIT["M"]), ("KB", UNIT["K"])):
        if abs(nbytes) >= mult:
            return f"{nbytes / mult:.2f} {label}"
    return f"{int(nbytes)} B"


def parse_top_size(text: str) -> int | None:
    m = re.fullmatch(r"([\d.]+)\s*([KMGT]?)B?", text.strip().upper())
    if not m:
        return None
    try:
        return int(float(m.group(1)) * UNIT[m.group(2)])
    except ValueError:
        return None


@dataclass
class Proc:
    pid: int
    uid: int
    mem: int
    path: str

    @property
    def name(self) -> str:
        return self.path.rsplit("/", 1)[-1].strip() or self.path


@dataclass
class Ctx:
    args: argparse.Namespace
    uid: int
    tty: bool
    state: dict
    ancestors: set
    protect: list
    ignored: dict = field(default_factory=dict)  # pid -> epoch when it may be offered again
    snooze_until: float = 0.0
    kill_all: bool = False


def run(cmd: list[str], timeout: int = 25) -> str:
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, errors="replace"
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return ""


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def top_memory() -> dict[int, int]:
    """pid -> physical footprint bytes for every process, in one cheap call."""
    out = run(["top", "-l", "1", "-n", "9999", "-o", "mem", "-stats", "pid,mem"])
    sizes: dict[int, int] = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        size = parse_top_size(parts[1])
        if size is not None:
            sizes[int(parts[0])] = size
    return sizes


def list_user_processes(uid: int) -> list[Proc]:
    sizes = top_memory()
    out = run(["ps", "-axo", "pid=,uid=,comm="])
    procs = []
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        try:
            pid, puid, path = int(parts[0]), int(parts[1]), parts[2]
        except ValueError:
            continue
        if puid != uid or pid not in sizes:
            continue
        procs.append(Proc(pid=pid, uid=puid, mem=sizes[pid], path=path))
    procs.sort(key=lambda p: p.mem, reverse=True)
    return procs


def command_line(pid: int) -> str:
    return run(["ps", "-p", str(pid), "-o", "args="]).strip()


def is_protected(p: Proc, ctx: Ctx) -> str | None:
    if p.pid == os.getpid() or p.pid in ctx.ancestors:
        return "this script or its parent shell"
    if p.pid <= 2:
        return "kernel/launchd"
    if p.name in PROTECTED_NAMES:
        return "protected system process"
    if any(p.path.startswith(pre) for pre in PROTECTED_PATH_PREFIXES):
        return "system path"
    low = p.path.lower()
    for pat in ctx.protect:
        if pat.lower() in low:
            return f"matches --protect {pat!r}"
    return None


def load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {"kills": {}}


def save_state(path: Path, state: dict) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(state))
    except OSError:
        pass


def recent_kills(state: dict, name: str, window: int) -> int:
    now = time.time()
    hits = [t for t in state["kills"].get(name, []) if now - t < window]
    if hits:
        state["kills"][name] = hits
    return len(hits)


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate(p: Proc, ctx: Ctx) -> bool:
    args = ctx.args
    try:
        if not args.force:
            os.kill(p.pid, signal.SIGTERM)
            deadline = time.time() + args.grace
            while time.time() < deadline:
                time.sleep(0.2)
                if not alive(p.pid):
                    return True
        os.kill(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        return True
    except PermissionError:
        log(f"      ! permission denied -- owned by uid {p.uid}, needs sudo")
        return False
    except OSError as exc:
        log(f"      ! kill failed: {exc}")
        return False
    deadline = time.time() + 3.0
    while time.time() < deadline and alive(p.pid):
        time.sleep(0.2)
    return not alive(p.pid)


def ask_gui(p: Proc, ctx: Ctx) -> str:
    """Native macOS modal. Returns 'kill', 'ignore', 'snooze' or 'timeout'."""
    args = ctx.args
    log(f"      showing a dialog for {p.name} (pid {p.pid}, {human(p.mem)}) -- waiting for you")
    head = (
        f"{p.name} is using {human(p.mem)}\n"
        f"Your limit is {human(args.threshold_bytes)}.\n\n"
        f"pid {p.pid}\n{p.path[:150]}\n\n"
    )
    countdown = "Force stop it?  This window closes by itself in %ds."
    try:
        cp = subprocess.run(
            ["osascript", "-l", "JavaScript", "-e", DIALOG_JS,
             "Mem Reaper - high memory", head, str(args.dialog_timeout),
             "Ignore|Snooze 15 min|Force Stop", "Force stop it?", countdown],
            capture_output=True, text=True, timeout=args.dialog_timeout + 45,
            errors="replace",
        )
    except subprocess.TimeoutExpired:
        log("      ! the dialog never came back; leaving the process alone")
        return "ignore"
    except OSError as exc:
        log(f"      ! osascript failed ({exc}); no GUI available, leaving it alone")
        return "ignore"
    out = cp.stdout.strip()
    if "Force Stop" in out:
        return "kill"
    if "Snooze" in out:
        return "snooze"
    if "Ignore" in out:
        return "ignore"
    if "TIMEOUT" in out:
        return "timeout"
    log(f"      ! unexpected dialog result {out!r} {cp.stderr.strip()[:120]!r}")
    return "ignore"


def ask_terminal(p: Proc, ctx: Ctx, index: int, total: int) -> str:
    args = ctx.args
    print(f"\n[{index}/{total}] {p.name}  (pid {p.pid})")
    print(f"    memory   : {human(p.mem)}    threshold: {human(args.threshold_bytes)}")
    print(f"    process  : {p.path[:110]}")
    argv = command_line(p.pid)
    if argv and argv != p.path:
        print(f"    command  : {argv[:110]}")
    if not ctx.tty:
        print("    -> not killed: no terminal to confirm in. Run it from Terminal,")
        print("       or use --yes if you really want unattended kills.")
        return "ignore"
    while True:
        try:
            ans = input("    kill it? [y]es / [n]o / [a]ll / [s]kip / [p]rotect / [q]uit > ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            return "quit"
        if ans in ("y", "yes", "k", "kill"):
            return "kill"
        if ans in ("", "n", "no", "s", "skip"):
            return "ignore"
        if ans in ("a", "all"):
            return "all"
        if ans in ("p", "protect"):
            return "protect"
        if ans in ("q", "quit"):
            return "quit"
        print("      ? enter y / n / a / s / p / q")


def ask(p: Proc, ctx: Ctx, index: int, total: int) -> str:
    if ctx.args.service or ctx.args.confirm_gui:
        return ask_gui(p, ctx)
    return ask_terminal(p, ctx, index, total)


def cycle(ctx: Ctx) -> int:
    args = ctx.args
    threshold = args.threshold_bytes
    procs = list_user_processes(ctx.uid)
    offenders = [p for p in procs if p.mem >= threshold]

    now = time.time()
    ctx.ignored = {pid: exp for pid, exp in ctx.ignored.items() if exp > now and alive(pid)}

    if args.service:
        if not offenders:
            return 0  # stay quiet when healthy so the log stays readable
        if now < ctx.snooze_until:
            log(f"snoozed -- {len(offenders)} over the limit, not asking; "
                f"{int((ctx.snooze_until - now) / 60) + 1} min left")
            return 0
    elif not offenders:
        log(f"nothing of yours over {human(threshold)}")
    else:
        log(f"{len(offenders)} of your process(es) over {human(threshold)}")

    killed = 0
    for i, p in enumerate(offenders, 1):
        why = is_protected(p, ctx)
        if why:
            log(f"[{i}/{len(offenders)}] {p.name} (pid {p.pid}) {human(p.mem)} -- SKIPPED, {why}")
            continue
        if p.pid in ctx.ignored:
            log(f"[{i}/{len(offenders)}] {p.name} (pid {p.pid}) {human(p.mem)} -- you already "
                f"declined this one; asking again in {int((ctx.ignored[p.pid] - time.time()) / 60) + 1} min")
            continue
        if recent_kills(ctx.state, p.name, args.loop_window) >= args.max_kills:
            log(f"[{i}/{len(offenders)}] {p.name} (pid {p.pid}) {human(p.mem)} -- SKIPPED, already "
                f"killed {args.max_kills}x in {args.loop_window // 60} min. It keeps respawning -- "
                f"quit its parent app instead of fighting it.")
            continue
        if not args.kill:
            log(f"[{i}/{len(offenders)}] {p.name} (pid {p.pid}) {human(p.mem)} -- would kill (dry run; add --kill)")
            continue

        if args.yes:
            log(f"[{i}/{len(offenders)}] {p.name} (pid {p.pid}) {human(p.mem)} -- killing, not asking (--yes)")
            decision = "kill"
        elif ctx.kill_all:
            decision = "kill"
        else:
            decision = ask(p, ctx, i, len(offenders))

        if decision == "quit":
            log("      stopped early; remaining processes untouched")
            break
        if decision == "protect":
            ctx.protect.append(p.name)
            log(f"      {p.name!r} added to the protect list for this run")
            continue
        if decision == "all":
            ctx.kill_all = True
            decision = "kill"
        if decision == "snooze":
            ctx.snooze_until = time.time() + args.snooze_minutes * 60
            log(f"      snoozed -- no more dialogs for {args.snooze_minutes} min")
            break
        if decision in ("ignore", "timeout"):
            quiet = (args.ignore_minutes if decision == "ignore" else args.timeout_reask_minutes) * 60
            ctx.ignored[p.pid] = time.time() + quiet
            log(f"      left alone: {p.name} (pid {p.pid}); quiet for {quiet // 60} min")
            continue

        log(f"      killing pid {p.pid} ({p.name}, {human(p.mem)}) ...")
        if terminate(p, ctx):
            log(f"      killed {p.name} (pid {p.pid}, was {human(p.mem)})")
            ctx.state["kills"].setdefault(p.name, []).append(time.time())
            save_state(args.state_file, ctx.state)
            killed += 1
        else:
            log("      STILL RUNNING (or it respawned under a new pid)")

    return killed


# Exit codes for --stop-pid, so a caller that cannot read the JSON line still
# knows which way it went. 2 is argparse's own.
STOP_OK = 0
STOP_REFUSED = 3
STOP_FAILED = 4


def stop_one(ctx: Ctx) -> int:
    """Stops the one process named by --stop-pid and answers with a JSON line.

    The confirmation already happened in the console that asked; what is left
    here is every rule a scan would apply -- the protected names and paths, the
    ancestor walk (which covers the console itself), and the owner check -- so
    a button in the app can never stop something this script would refuse to.
    """
    args = ctx.args
    pid = args.stop_pid

    def answer(result: str, code: int, **extra) -> int:
        print(json.dumps({"result": result, "pid": pid, **extra}), flush=True)
        return code

    out = run(["ps", "-p", str(pid), "-o", "uid=,comm="]).strip()
    parts = out.split(None, 1)
    if len(parts) != 2 or not parts[0].isdigit():
        return answer("gone", STOP_OK, reason="it is no longer running")
    p = Proc(pid=pid, uid=int(parts[0]), mem=0, path=parts[1].strip())

    # A pid is only a name for as long as the process lives. If the one the
    # user picked has exited and the number was reused, stopping it would stop
    # something they never saw.
    if args.expect_path and p.path != args.expect_path:
        return answer("changed", STOP_REFUSED, name=p.name,
                      reason=f"pid {pid} is now {p.path}, not the process you picked")
    if p.uid != ctx.uid:
        return answer("not_yours", STOP_REFUSED, name=p.name,
                      reason=f"it belongs to uid {p.uid}; only your own processes are stopped")
    why = is_protected(p, ctx)
    if why:
        return answer("protected", STOP_REFUSED, name=p.name, reason=why)

    if terminate(p, ctx):
        ctx.state["kills"].setdefault(p.name, []).append(time.time())
        save_state(args.state_file, ctx.state)
        return answer("stopped", STOP_OK, name=p.name)
    return answer("still_running", STOP_FAILED, name=p.name,
                  reason="it did not exit, or it respawned under a new pid")


def parse_args(argv=None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="Report (and optionally kill) your own high-memory macOS processes.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--threshold-mb", type=int, default=1024,
                    help="what counts as too much, in MB (default 1024 = 1 GB)")
    ap.add_argument("--kill", action="store_true", help="offer to kill each offender (default: report only)")
    ap.add_argument("--watch", type=int, metavar="SECONDS", nargs="?", const=30,
                    help="keep running and re-check (default every 30s)")
    ap.add_argument("--service", action="store_true",
                    help="background mode: one modal dialog per offender, loops forever")
    ap.add_argument("--confirm-gui", action="store_true",
                    help="one-shot scan that confirms with a macOS modal instead of the terminal")
    ap.add_argument("--interval", type=int, default=30, metavar="SECONDS",
                    help="seconds between checks in --service mode (default 30)")
    ap.add_argument("--dialog-timeout", type=int, default=45, metavar="SECONDS",
                    help="seconds before a dialog dismisses itself (default 45)")
    ap.add_argument("--ignore-minutes", type=int, default=30, metavar="MIN",
                    help="minutes to stay quiet about a process you clicked Ignore on (default 30)")
    ap.add_argument("--snooze-minutes", type=int, default=15, metavar="MIN",
                    help="minutes the Snooze button suppresses all dialogs (default 15)")
    ap.add_argument("--timeout-reask-minutes", type=int, default=5, metavar="MIN",
                    help="minutes before a dialog you never answered comes back (default 5)")
    ap.add_argument("--top", type=int, default=15, help="also list your N biggest processes (0 to hide)")
    ap.add_argument("--grace", type=float, default=3.0, help="seconds after SIGTERM before SIGKILL (default 3)")
    ap.add_argument("--force", action="store_true", help="skip SIGTERM, go straight to SIGKILL")
    ap.add_argument("--yes", action="store_true",
                    help="kill without asking at all. Dry-run the list before using this")
    ap.add_argument("--protect", action="append", default=[], metavar="SUBSTR",
                    help="extra name/path substring to never kill (repeatable)")
    ap.add_argument("--max-kills", type=int, default=3, metavar="N",
                    help="stop re-killing the same process name after N times (default 3)")
    ap.add_argument("--loop-window", type=int, default=600, metavar="SECONDS",
                    help="window for --max-kills (default 600)")
    ap.add_argument("--state-file", type=Path, default=Path.home() / ".mem_reaper_state.json",
                    help="respawn-guard history (default ~/.mem_reaper_state.json)")
    ap.add_argument("--stop-pid", type=int, metavar="PID",
                    help="stop this one process now, with no prompt, and print the outcome as JSON. "
                         "For a caller that has already asked you; protected processes are still refused")
    ap.add_argument("--expect-path", metavar="PATH",
                    help="with --stop-pid: refuse unless the pid is still this executable")

    args = ap.parse_args(argv)
    if args.expect_path and args.stop_pid is None:
        ap.error("--expect-path only means something with --stop-pid")
    args.threshold_bytes = args.threshold_mb * 1024**2
    if args.threshold_mb < 64:
        ap.error("--threshold-mb below 64 is a good way to kill your whole session by accident")
    if args.service:
        args.kill = True
        args.yes = False
        args.top = 0
        args.watch = max(5, args.interval)
    if args.confirm_gui:
        args.kill = True
        args.yes = False
    return args


def main(argv=None) -> int:
    args = parse_args(argv)
    # so progress is visible when piped to a log file in --watch/--service mode
    sys.stdout.reconfigure(line_buffering=True)
    install_stop_handlers()

    ctx = Ctx(
        args=args,
        uid=os.getuid(),
        tty=sys.stdin.isatty(),
        state=load_state(args.state_file),
        ancestors=set(),
        protect=list(args.protect),
    )
    pid = os.getppid()
    while pid > 1 and pid not in ctx.ancestors:
        ctx.ancestors.add(pid)
        out = run(["ps", "-o", "ppid=", "-p", str(pid)]).strip()
        try:
            pid = int(out)
        except ValueError:
            break

    if args.stop_pid is not None:
        return stop_one(ctx)

    if args.service:
        log(f"service started (pid {os.getpid()}): checking every {args.watch}s, limit "
            f"{human(args.threshold_bytes)}, dialogs dismiss themselves after {args.dialog_timeout}s")
    elif args.confirm_gui:
        log(f"mode: ONE-SHOT SCAN, confirmed with a macOS dialog (threshold {human(args.threshold_bytes)})")
    elif not args.kill:
        log(f"mode: REPORT ONLY -- add --kill to be asked about each one (threshold {human(args.threshold_bytes)})")
    elif args.yes:
        log(f"mode: KILL WITHOUT ASKING (threshold {human(args.threshold_bytes)})")
    else:
        note = "" if ctx.tty else " -- no terminal, so nothing can be confirmed"
        log(f"mode: KILL, confirmed one by one (threshold {human(args.threshold_bytes)}){note}")

    watching = args.watch is not None
    interval = args.watch or 30
    first = True
    try:
        while True:
            started = time.time()
            killed = cycle(ctx)

            if first and args.top:
                procs = list_user_processes(ctx.uid)[: args.top]
                print(f"\n--- your top {len(procs)} by memory ---")
                for p in procs:
                    print(f"  {human(p.mem):>10}  pid {p.pid:<6} {p.name[:34]:<34} {p.path[:62]}")
                first = False

            if killed:
                log(f"{killed} process(es) terminated")

            if not watching:
                break
            if not args.service:
                print(f"\nnext check in {interval}s  (Ctrl-C to stop)")
            # don't stack another full interval on top of a dialog you sat with
            time.sleep(max(1.0, interval - (time.time() - started)))
    except (StopRequested, KeyboardInterrupt):
        log("stopped")

    save_state(args.state_file, ctx.state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
