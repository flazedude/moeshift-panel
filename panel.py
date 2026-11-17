#!/usr/bin/env python3
"""MoEShift control panel — start/stop the server and watch its progress.

Pure standard library, works with Python 3.9+ from Command Line Tools.

  python3 moeshift-panel.py          # interactive panel (Ctrl-C to leave UI)

Keys
  s  start server            x  stop server (it only stops what it started)
  g  restart                 l  toggle log follow on/off
  r  redraw / refresh now    q  quit the panel (leaves the server running)
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
BIN = os.path.join(HOME, ".local/bin/moeshift")
CONFIG = os.path.join(HOME, ".config/moeshift/config.json")
LOG = os.path.join(HOME, "Library/Logs/moeshift.log")
PIDFILE = os.path.join(HOME, "Library/Logs/moeshift.panel.pid")
BASE = "http://127.0.0.1:8080"

# ---------------------------------------------------------------- utilities


def term_width():
    try:
        return shutil.get_terminal_size((100, 30)).columns
    except Exception:
        return 100


def clear():
    sys.stdout.write("\033[2J\033[H")
    sys.stdout.flush()


def style(text, code):
    if not sys.stdout.isatty() or os.environ.get("NO_COLOR"):
        return text
    return "\033[%sm%s\033[0m" % (code, text)


def dim(t):
    return style(t, "2")


def bold(t):
    return style(t, "1")


def green(t):
    return style(t, "32")


def red(t):
    return style(t, "31")


def yellow(t):
    return style(t, "33")


def cyan(t):
    return style(t, "36")


def http_get(path, timeout=2.0, attempts=3):
    """GET a path, retrying briefly.

    The server occasionally answers GET with a 404 while a long generation is
    running, then recovers; a single probe would show a false "unavailable".
    """
    last_code, last_body = None, ""
    for i in range(attempts):
        try:
            with urllib.request.urlopen(BASE + path, timeout=timeout) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            last_code = e.code
            last_body = e.read().decode("utf-8", "replace")[:200]
            if e.code != 404:
                break
        except Exception as exc:  # connection refused, timeout, ...
            last_code, last_body = None, str(exc)
        if i < attempts - 1:
            time.sleep(0.4)
    return last_code, last_body


# ------------------------------------------------------------ process control


def active_log():
    """The panel's own instances log to LOG; one started elsewhere may not."""
    if pid_file_read() and os.path.exists(LOG):
        return LOG
    return LOG


def pid_file_read():
    try:
        with open(PIDFILE) as f:
            return int(f.read().strip())
    except Exception:
        return None


def server_pids():
    """Return pids whose command line is the moeshift server (not children)."""
    try:
        out = subprocess.run(
            ["ps", "-Ao", "pid=,command="], capture_output=True, text=True
        ).stdout
    except Exception:
        return []
    pids = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        pid, _, cmd = line.partition(" ")
        if "moeshift" in cmd and "--config" in cmd and "moeshift-panel" not in cmd:
            try:
                pids.append(int(pid))
            except ValueError:
                pass
    return pids


def is_running():
    """Prefer a verified HTTP health check over process sniffing."""
    code, _ = http_get("/health", timeout=1.5)
    return code == 200


def start_server():
    if is_running():
        return False, "Already running."
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    logf = open(LOG, "ab", buffering=0)
    # Start detached from this terminal so the panel can close and the server lives on.
    proc = subprocess.Popen(
        [BIN, "--config", CONFIG],
        stdout=logf,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    with open(PIDFILE, "w") as f:
        f.write(str(proc.pid))
    return True, "Starting (pid %d), loading model..." % proc.pid


def stop_server(adopt_orphan=False):
    """Stop the instance this panel started.

    With adopt_orphan, a moeshift server running outside the panel may also be
    stopped, so the user can hand it over to the panel. Only processes whose
    command line is the moeshift server are eligible.
    """
    pid = pid_file_read()
    if not pid and adopt_orphan:
        found = server_pids()
        pid = found[0] if found else None
        if not pid:
            return False, "No running server found."
        try:
            os.kill(pid, signal.SIGTERM)
        except Exception as exc:
            return False, "Stop failed: %s" % exc
        for _ in range(20):
            time.sleep(0.25)
            if not is_running():
                break
        return True, "Stopped the instance running outside the panel."
    if not pid:
        return False, "This panel did not start the server; not stopping it."
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except ProcessLookupError:
        try:
            os.remove(PIDFILE)
        except OSError:
            pass
        return False, "Process already gone."
    except Exception:
        try:
            os.kill(pid, signal.SIGTERM)
        except Exception as exc:
            return False, "Stop failed: %s" % exc
    # Give it a moment, then force if needed.
    for _ in range(20):
        time.sleep(0.25)
        if not is_running():
            break
    else:
        try:
            os.killpg(os.getpgid(pid), signal.SIGKILL)
        except Exception:
            pass
    try:
        os.remove(PIDFILE)
    except OSError:
        pass
    return True, "Stopped."


# ------------------------------------------------------------- log analysis

RE_PREP = re.compile(r"prompt processing, n_tokens\s*=\s*(\d+), progress = ([\d.]+)")
RE_PRINT = re.compile(r"prompt eval time =\s*([\d.]+) ms /\s*(\d+) tokens.*?([\d.]+) tokens per second")
RE_GEN = re.compile(r"eval time =\s*([\d.]+) ms /\s*(\d+) tokens.*?([\d.]+) tokens per second")
RE_TG = re.compile(r"n_decoded\s*=\s*(\d+), tg\s*=\s*([\d.]+) t/s")
RE_LOAD = re.compile(r"load_model: loading model '([^']+)'")
RE_TASK = re.compile(r"task (\d+) \| processing task")
RE_IDLE = re.compile(r"all slots are idle")
RE_ERR = re.compile(r"\b(error|failed|Exception|abort)\b", re.I)


def log_tail(path, nbytes=400_000):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > nbytes:
                f.seek(size - nbytes)
                f.readline()
            return f.read().decode("utf-8", "replace").splitlines()
    except Exception:
        return []


def summarize(lines):
    """Pull the interesting signals out of recent log lines."""
    info = {
        "loaded": None,
        "prompt_progress": None,
        "last_prompt": None,
        "last_gen": None,
        "last_tg": None,
        "busy": False,
        "errors": [],
    }
    for ln in lines:
        m = RE_LOAD.search(ln)
        if m:
            info["loaded"] = os.path.basename(m.group(1))
        m = RE_PREP.search(ln)
        if m:
            info["prompt_progress"] = (int(m.group(1)), float(m.group(2)))
            info["busy"] = True
        m = RE_PRINT.search(ln)
        if m:
            info["last_prompt"] = (int(m.group(2)), float(m.group(3)), float(m.group(1)))
        m = RE_GEN.search(ln)
        if m:
            info["last_gen"] = (int(m.group(2)), float(m.group(3)))
        m = RE_TG.search(ln)
        if m:
            info["last_tg"] = (int(m.group(1)), float(m.group(2)))
            info["busy"] = True
        if RE_TASK.search(ln):
            info["busy"] = True
        if RE_IDLE.search(ln):
            info["busy"] = False
            info["prompt_progress"] = None
        if RE_ERR.search(ln) and "http client error" not in ln:
            info["errors"].append(ln.strip())
    info["errors"] = info["errors"][-3:]
    return info


# ------------------------------------------------------------------- render


def render(follow, last_note, rows=18):
    W = term_width()
    up = is_running()
    mpid = pid_file_read()
    panel_owns = bool(mpid)

    clear()
    print(bold("  MoEShift control panel") + dim("   " + time.strftime("%H:%M:%S")))
    print(dim("  " + "-" * min(W - 2, 78)))

    # --- status
    state = green("● RUNNING") if up else red("○ STOPPED")
    print("  Server   %s" % state, end="")
    if panel_owns:
        print(dim("  (started by this panel, pid %d)" % mpid))
    else:
        others = server_pids()
        if up and others:
            print(dim("  (running outside this panel, pid %d)" % others[0]))
            print(dim("  Activity and log below come from %s," % LOG))
            print(dim("  which this instance may not be writing to. Press x then s")) 
            print(dim("  to hand it over to the panel."))
        else:
            print()

    code, body = http_get("/v1/models", timeout=3.0)
    if code == 200:
        try:
            ids = [m["id"] for m in json.loads(body).get("data", [])]
            print("  Model    %s" % ", ".join(ids))
        except Exception:
            print("  Model    " + dim("(unreadable /v1/models)"))
    elif code is None:
        print("  Model    " + dim("server not reachable"))
    else:
        print("  Model    " + dim("HTTP %s from /v1/models" % code))

    # --- endpoints
    print()
    print("  " + bold("Endpoints"))
    checks = [("/health", "liveness"), ("/v1/models", "model list"),
              ("/v1/chat/completions", "chat (POST)")]
    for path, label in checks:
        if path.endswith("completions"):
            print("    %-24s %s %s" % (path, dim("—"), dim(label)))
            continue
        c, _ = http_get(path, timeout=2.0)
        mark = green("200") if c == 200 else (red(str(c)) if c else dim("off"))
        print("    %-24s %-6s %s" % (path, mark, dim("→ " + BASE + path)))
    print("    %-24s %s" % ("/metrics /props /slots", dim("404 in this build")))

    # --- activity from logs
    lines = log_tail(LOG)
    info = summarize(lines)
    print()
    print("  " + bold("Activity"))
    if info["loaded"]:
        print("    loaded   %s" % dim(info["loaded"]))
    if info["prompt_progress"]:
        n, prog = info["prompt_progress"]
        width = 24
        filled = int(width * prog)
        bar = "#" * filled + "-" * (width - filled)
        print("    prefill  [%s] %3d%%  %s" % (bar, int(prog * 100), dim("%d tokens" % n)))
    else:
        busy = info["busy"]
        print("    prefill  %s" % (yellow("working…") if busy else dim("idle (no prompt processing)")))
    if info["last_prompt"]:
        n, tps, ms = info["last_prompt"]
        print("    last prompt  %d tokens @ %.1f tok/s" % (n, tps))
    if info["last_gen"]:
        n, tps = info["last_gen"]
        print("    last output  %d tokens @ %.2f tok/s" % (n, tps))
    if info["last_tg"]:
        n, tg = info["last_tg"]
        print("    streaming    %d decoded, %.2f tok/s" % (n, tg))
    for e in info["errors"]:
        print("    " + red("error: ") + e[:W - 16])

    # --- log tail
    print()
    follow_note = green("FOLLOWING") if follow else dim("paused (g)")
    print("  " + bold("Log") + "  " + dim(LOG) + "  " + follow_note)
    tail = lines[-rows:] if lines else ["(no log yet — start the server with 's')"]
    for ln in tail:
        print("    " + ln[:W - 6])

    # --- footer
    print()
    print(dim("  s start   x stop   g %s   q quit" % ("pause" if follow else "follow")))
    if last_note:
        print("  " + cyan(last_note))


# --------------------------------------------------------------------- main


def read_key(timeout):
    """Block up to `timeout` seconds for a single keypress; None on timeout."""
    import select
    import termios
    import tty

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        r, _, _ = select.select([sys.stdin], [], [], timeout)
        if r:
            return sys.stdin.read(1)
        return None
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def main():
    if not sys.stdin.isatty():
        print("Run this in a terminal (it needs keyboard input).", file=sys.stderr)
        return 1
    if not os.path.exists(BIN):
        print("moeshift not found at %s" % BIN, file=sys.stderr)
        return 1
    follow = True
    note = ""
    try:
        while True:
            render(follow, note)
            note = ""
            key = read_key(2.0 if follow else 10.0)
            if key is None:
                continue
            key = key.lower()
            if key == "q":
                break
            elif key == "s":
                ok, note = start_server()
            elif key == "x":
                ok, note = stop_server(adopt_orphan=True)
            elif key == "g":
                follow = not follow
            elif key == "r":
                pass
    except KeyboardInterrupt:
        pass
    print()
    print("Left the panel. The server keeps running if it was started.")
    print("Reopen with: python3 %s" % os.path.abspath(__file__))
    print("Stop it with: kill $(cat %s)" % PIDFILE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
