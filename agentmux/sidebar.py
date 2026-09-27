"""agentmux sidebar renderer: one pane per tmux server listing every agent on it.

Data: one ``tmux list-panes -a -F`` per tick (fields from :data:`FIELDS`), agents from their
``@agentmux_*`` pane options. Wake-ups come from a second-aligned timer, a ``tmux wait-for
agentmux-redraw`` latch the hooks signal, and SIGWINCH. Output is a line-level diff repaint on
the alternate screen.
"""

from __future__ import annotations

import argparse
import contextlib
import logging
import logging.handlers
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import unicodedata
from dataclasses import dataclass, field

OPT = "@agentmux_"
SEP = "\x1f"
REDRAW_CHANNEL = "agentmux-redraw"
SIDEBAR_TITLE = "agentmux-sidebar"
SHELLS = frozenset({"zsh", "bash", "fish", "sh", "dash", "ksh", "nu"})
SHELL_GRACE = 15  # seconds a just-exited agent keeps its row while the shell is back
DEFAULT_TTL = 14400
STATES = ("blocked", "done", "delegating", "working", "idle")  # worst first
PRIORITY = {s: i for i, s in enumerate(STATES)}

FIELDS: tuple[tuple[str, str], ...] = (
    ("pane_id", "#{pane_id}"),
    ("session_id", "#{session_id}"),
    ("session_name", "#{session_name}"),
    ("window_id", "#{window_id}"),
    ("window_index", "#{window_index}"),
    ("window_name", "#{window_name}"),
    ("pane_index", "#{pane_index}"),
    ("window_active", "#{window_active}"),
    ("session_attached", "#{session_attached}"),
    ("pane_active", "#{pane_active}"),
    ("pane_dead", "#{pane_dead}"),
    ("pane_current_command", "#{pane_current_command}"),
    ("pane_width", "#{pane_width}"),
    ("pane_height", "#{pane_height}"),
    ("state", "#{" + OPT + "state}"),
    ("kind", "#{" + OPT + "kind}"),
    ("project", "#{" + OPT + "project}"),
    ("start", "#{" + OPT + "start}"),
    ("subagents", "#{" + OPT + "subagents}"),
    ("detail", "#{" + OPT + "detail}"),
    ("sid", "#{" + OPT + "sid}"),
    ("updated", "#{" + OPT + "updated}"),
    ("sidebar", "#{" + OPT + "sidebar}"),
)
FIELD_NAMES = tuple(n for n, _ in FIELDS)
LIST_FORMAT = SEP.join(f for _, f in FIELDS)

GLYPH = {
    "working": "●",  # ●
    "idle": "·",  # ·
    "blocked": "\U000f0e07",  # nf-md-hand_back_right
    "done": "\U000f012c",  # nf-md-check
    "delegating": "\U000f0010",  # nf-md-account-multiple
    "ellipsis": "…",
    "rule": "─",
    "sep": "·",
}
COLOR_KEYS = (
    "blocked",
    "done",
    "delegating",
    "working",
    "idle",
    "project",
    "agent",
    "text",
    "fg",
    "dim",
    "sidebar_bg",
)
DEFAULT_COLORS = {
    "blocked": "red",
    "done": "green",
    "delegating": "magenta",
    "working": "yellow",
    "idle": "colour240",
    "project": "cyan",
    "agent": "colour245",
    "text": "white",
    "fg": "default",
    "dim": "colour240",
    "sidebar_bg": "default",
}
NAMED = {
    "black": 30,
    "red": 31,
    "green": 32,
    "yellow": 33,
    "blue": 34,
    "magenta": 35,
    "cyan": 36,
    "white": 37,
}

log = logging.getLogger("agentmux.sidebar")


# ----------------------------------------------------------------------------- cells ----


def cell_width(ch: str) -> int:
    o = ord(ch)
    if o < 32 or 0x7F <= o < 0xA0:
        return 0
    if unicodedata.combining(ch):
        return 0
    if 0xE000 <= o <= 0xF8FF or 0xF0000 <= o <= 0x10FFFD:
        return 1  # private use: Nerd Font glyphs render as one cell
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


def str_width(text: str) -> int:
    return sum(cell_width(c) for c in text)


def fit(text: str, width: int, align: str = "left") -> str:
    """Exactly ``width`` cells: truncate with an ellipsis, pad with spaces."""
    if width <= 0:
        return ""
    w = str_width(text)
    if w > width:
        out = []
        used = 0
        for c in text:
            cw = cell_width(c)
            if used + cw > width - 1:
                break
            out.append(c)
            used += cw
        text = "".join(out) + GLYPH["ellipsis"]
        w = used + 1
    pad = width - w
    if align == "right":
        return " " * pad + text
    return text + " " * pad


# ---------------------------------------------------------------------------- colours ----


def sgr(color: str) -> str:
    """tmux colour spec -> SGR foreground parameters ('' for default)."""
    c = (color or "").strip().lower()
    if not c or c == "default":
        return "39"
    if c.startswith("#") and len(c) == 7:
        try:
            r, g, b = (int(c[i : i + 2], 16) for i in (1, 3, 5))
            return f"38;2;{r};{g};{b}"
        except ValueError:
            return "39"
    m = re.fullmatch(r"colou?r(\d{1,3})", c)
    if m:
        return f"38;5;{int(m.group(1)) % 256}"
    if c.startswith("bright") and c[6:] in NAMED:
        return str(NAMED[c[6:]] + 60)
    if c in NAMED:
        return str(NAMED[c])
    return "39"


class Theme:
    def __init__(self, colors: dict[str, str], enabled: bool = True):
        self.enabled = enabled
        self.codes = {k: sgr(colors.get(k, DEFAULT_COLORS[k])) for k in COLOR_KEYS}

    def paint(self, text: str, key: str, bold: bool = False) -> str:
        if not self.enabled or not text:
            return text
        code = self.codes.get(key, "39")
        if bold:
            code += ";1"
        return f"\x1b[{code}m{text}\x1b[0m"


# ------------------------------------------------------------------------------ model ----


@dataclass
class Agent:
    target: str
    project: str
    kind: str
    state: str
    start: int
    updated: int
    subagents: int
    detail: str
    pane_id: str
    session: str = ""
    window: int = 0

    @property
    def priority(self) -> int:
        return PRIORITY.get(self.state, 99)


@dataclass
class Model:
    agents: list[Agent] = field(default_factory=list)  # worst first
    counts: dict[str, int] = field(default_factory=dict)
    now: int = 0


def _int(v: str, default: int = 0) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def parse_rows(text: str, sep: str = SEP) -> list[dict[str, str]]:
    rows = []
    for line in text.split("\n"):
        if not line:
            continue
        parts = line.split(sep)
        if len(parts) < len(FIELD_NAMES):
            parts += [""] * (len(FIELD_NAMES) - len(parts))
        rows.append(dict(zip(FIELD_NAMES, parts)))
    return rows


def is_shell(cmd: str) -> bool:
    return cmd.lstrip("-") in SHELLS


def build_model(
    rows: list[dict[str, str]],
    now: float,
    self_pane: str,
    ttl: int = DEFAULT_TTL,
) -> Model:
    now_i = int(now)
    seen: set[str] = set()
    agents: list[Agent] = []
    for r in rows:
        if r["pane_id"] == self_pane or r["pane_dead"] == "1" or r["sidebar"] == "1":
            continue
        # A pane in a window shared by grouped sessions is listed once per session.
        if not r["state"] or r["pane_id"] in seen:
            continue
        updated = _int(r["updated"])
        if is_shell(r["pane_current_command"]) and not (updated and now_i - updated < SHELL_GRACE):
            continue
        seen.add(r["pane_id"])
        state = r["state"] if r["state"] in STATES else "idle"
        if updated and now_i - updated > ttl:
            state = "idle"
        agents.append(
            Agent(
                target=f"{r['session_name']}:{r['window_index']}.{r['pane_index']}",
                project=r["project"],
                kind=r["kind"],
                state=state,
                start=_int(r["start"]) if state not in ("idle", "done") else 0,
                updated=updated,
                subagents=_int(r["subagents"]),
                detail=r["detail"],
                pane_id=r["pane_id"],
                session=r["session_name"],
                window=_int(r["window_index"]),
            )
        )
    agents.sort(key=lambda a: (a.priority, -a.updated, a.session, a.window, a.target))
    model = Model(agents=agents, now=now_i)
    for a in agents:
        model.counts[a.state] = model.counts.get(a.state, 0) + 1
    return model


# ----------------------------------------------------------------------------- layout ----


def fmt_elapsed(secs: int) -> str:
    if secs < 0:
        secs = 0
    if secs < 3600:
        return f"{secs // 60}m{secs % 60:02d}s"
    return f"{secs // 3600}h{(secs % 3600) // 60:02d}m"


def fmt_ago(secs: int) -> str:
    if secs < 60:
        return f"{max(secs, 0)}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


class Frame:
    """Builds lines that are exactly ``width`` cells wide (colour codes excluded)."""

    def __init__(self, width: int, theme: Theme):
        self.width = width
        self.theme = theme
        self.lines: list[str] = []
        self.rows: list[tuple[int, str, str]] = []  # (y, target, pane_id) for click-to-jump

    def add(self, segments: list[tuple[str, int, str, str]]) -> None:
        """segments: (text, width, colour key, align). Widths must sum to self.width."""
        out = []
        for text, width, key, align in segments:
            out.append(self.theme.paint(fit(text, width, align), key))
        self.lines.append("".join(out))

    def text(self, text: str, key: str = "fg") -> None:
        self.add([(text, self.width, key, "left")])


def render(
    model: Model,
    width: int,
    height: int,
    theme: Theme,
    density: str = "full",
) -> Frame:
    frame = Frame(width, theme)
    now = model.now
    # header: " agents" + right-aligned count pills, worst state first
    pills = []
    pill_width = 0
    for state in STATES:
        n = model.counts.get(state, 0)
        if n:
            piece = f"{GLYPH[state]} {n}"
            pills.append((piece, state))
            pill_width += str_width(piece) + 1
    left = " agents"
    if pill_width and str_width(left) + pill_width <= width:
        segs: list[tuple[str, int, str, str]] = [(left, width - pill_width, "fg", "left")]
        for piece, state in pills:
            segs.append((" " + piece, str_width(piece) + 1, state, "left"))
        frame.add(segs)
    else:
        frame.text(left)
    frame.text(GLYPH["rule"] * width, "dim")

    if not model.agents:
        frame.text(" no agents", "dim")
    per_agent = 1 if density == "compact" else 2
    total = len(model.agents)
    fits = len(frame.lines) + per_agent * total <= height
    limit = height if fits else height - 1  # keep a line for the "+N more" footer
    shown = 0
    for a in model.agents:
        if len(frame.lines) + per_agent > limit:
            break
        elapsed = fmt_elapsed(now - a.start) if a.start else ""
        # "  <icon> <target 8> <project:kind 25> <elapsed 6> " = 3+9+1+25+7+1 cells
        label_w = width - 21
        proj = a.project or "?"
        pw = min(label_w, max(str_width(proj), 1))
        frame.rows.append((len(frame.lines), a.target, a.pane_id))
        frame.add(
            [
                ("  " + GLYPH[a.state], 3, a.state, "left"),
                (" " + a.target, 9, "dim", "left"),
                (" ", 1, "fg", "left"),
                (proj, pw, "project", "left"),
                *_kind_segments(a, label_w - pw),
                (" " + elapsed, 7, "text", "right"),
                (" ", 1, "fg", "left"),
            ]
        )
        if per_agent == 2:
            frame.add(_detail_segments(a, width, now))
        shown += 1
    hidden = total - shown
    if hidden > 0:
        frame.text(f" +{hidden} more", "dim")
    while len(frame.lines) < height:
        frame.text("")
    del frame.lines[height:]
    return frame


def _kind_segments(a: Agent, rest: int) -> list[tuple[str, int, str, str]]:
    if rest <= 0:
        return []
    kind = a.kind or "?"
    return [(":", min(1, rest), "dim", "left"), (kind, max(rest - 1, 0), "agent", "left")]


def _detail_segments(a: Agent, width: int, now: int) -> list[tuple[str, int, str, str]]:
    inner = width - 5
    if a.state == "blocked":
        return [
            ("    ", 4, "fg", "left"),
            (f"needs you {GLYPH['sep']} {a.detail}".rstrip(" ·"), inner, "blocked", "left"),
            (" ", 1, "fg", "left"),
        ]
    if a.state == "delegating":
        text = f"{GLYPH['delegating']} {a.subagents}"
        if a.detail:
            text += f" {GLYPH['sep']} {a.detail}"
        return [
            ("    ", 4, "fg", "left"),
            (text, inner, "delegating", "left"),
            (" ", 1, "fg", "left"),
        ]
    if a.state == "working":
        text = a.detail or "working"
        if a.subagents:
            text += f" {GLYPH['sep']} {GLYPH['delegating']} {a.subagents}"
        return [("    ", 4, "fg", "left"), (text, inner, "fg", "left"), (" ", 1, "fg", "left")]
    if a.state == "done":
        ago = fmt_ago(now - a.updated) if a.updated else "?"
        return [
            ("    ", 4, "fg", "left"),
            (f"finished {ago} ago", inner, "done", "left"),
            (" ", 1, "fg", "left"),
        ]
    return [("    ", 4, "fg", "left"), ("idle", inner, "dim", "left"), (" ", 1, "fg", "left")]


# ------------------------------------------------------------------------------- term ----


class Term:
    def __init__(self, fd: int = 1):
        self.fd = fd
        self.prev: list[str] = []
        self.active = False

    def write(self, data: str) -> None:
        with contextlib.suppress(OSError):
            os.write(self.fd, data.encode("utf-8", "replace"))

    def enter(self) -> None:
        self.write("\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[2J\x1b[H")
        self.active = True

    def leave(self) -> None:
        if self.active:
            self.write("\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l")
            self.active = False

    def draw(self, lines: list[str], full: bool = False) -> int:
        out = []
        if full:
            out.append("\x1b[2J")
            self.prev = []
        for y, line in enumerate(lines):
            if y < len(self.prev) and self.prev[y] == line:
                continue
            out.append(f"\x1b[{y + 1};1H{line}\x1b[0m")
        data = "".join(out)
        if data:
            self.write(data)
        self.prev = list(lines)
        return len(data)


# ------------------------------------------------------------------------------- tmux ----


class Tmux:
    def __init__(self, binary: str, socket_args: list[str]):
        self.binary = binary
        self.socket_args = socket_args

    def run(self, *args: str, timeout: float = 5.0) -> str:
        res = subprocess.run(
            [self.binary, *self.socket_args, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        if res.returncode != 0:
            raise RuntimeError(res.stderr.strip() or f"tmux {args[0]} failed")
        return res.stdout

    def list_panes(self) -> list[dict[str, str]]:
        return parse_rows(self.run("list-panes", "-a", "-F", LIST_FORMAT))

    def display(self, fmt: str, target: str | None = None) -> str:
        args = ["display", "-p"]
        if target:
            args += ["-t", target]
        return self.run(*args, fmt).rstrip("\n")


# ------------------------------------------------------------------------------ waker ----


class Waker:
    def __init__(self, tmux: Tmux):
        self.tmux = tmux
        self.event = threading.Event()
        self.stop = threading.Event()
        self.resized = False
        self.period = 1.0
        self.proc: subprocess.Popen | None = None

    def start(self) -> None:
        threading.Thread(target=self._timer, daemon=True).start()
        threading.Thread(target=self._latch, daemon=True).start()
        with contextlib.suppress(ValueError, AttributeError):
            signal.signal(signal.SIGWINCH, self._winch)

    def _winch(self, *_: object) -> None:
        self.resized = True
        self.event.set()

    def _timer(self) -> None:
        while not self.stop.is_set():
            now = time.time()
            delay = self.period - (now % self.period)
            if self.stop.wait(delay):
                break
            self.event.set()

    def _latch(self) -> None:
        failures = 0
        while not self.stop.is_set():
            try:
                self.proc = subprocess.Popen(
                    [self.tmux.binary, *self.tmux.socket_args, "wait-for", REDRAW_CHANNEL],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                rc = self.proc.wait()
            except OSError:
                rc = 1
            if self.stop.is_set():
                break
            if rc != 0:
                failures += 1
                if failures >= 2:
                    log.warning("tmux wait-for failed twice, server gone; exiting")
                    self.stop.set()
                    self.event.set()
                    break
                time.sleep(0.5)
                continue
            failures = 0
            self.event.set()

    def wait(self) -> bool:
        """Block until something happened. Returns False when the renderer should exit."""
        self.event.wait()
        time.sleep(0.03)  # coalesce bursts
        self.event.clear()
        return not self.stop.is_set()

    def shutdown(self) -> None:
        self.stop.set()
        self.event.set()
        if self.proc and self.proc.poll() is None:
            with contextlib.suppress(OSError):
                self.proc.terminate()


def read_theme(tmux: Tmux) -> tuple[dict[str, str], int, int, str]:
    fields = [f"#{{{OPT}color_{k}}}" for k in COLOR_KEYS]
    fields += [
        f"#{{{OPT}width}}",
        f"#{{{OPT}ttl}}",
        f"#{{{OPT}sidebar_density}}",
    ]
    raw = tmux.display(SEP.join(fields))
    parts = raw.split(SEP)
    if len(parts) != len(fields):
        parts = [""] * len(fields)
    colors = {k: parts[i] for i, k in enumerate(COLOR_KEYS)}
    width = _int(parts[len(COLOR_KEYS)], 46)
    ttl = _int(parts[len(COLOR_KEYS) + 1], DEFAULT_TTL)
    density = parts[len(COLOR_KEYS) + 2] or "full"
    return colors, width, ttl, density


def scratch_dir(server_pid: str) -> str:
    base = os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
    user = os.environ.get("USER") or os.environ.get("LOGNAME") or "u"
    return os.path.join(base.rstrip("/"), f"agentmux-{user}", server_pid)


def setup_logging(verbose: bool) -> None:
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    path = os.path.join(state, "agentmux", "sidebar.log")
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        handler: logging.Handler = logging.handlers.RotatingFileHandler(
            path, maxBytes=256 * 1024, backupCount=1
        )
    except OSError:
        handler = logging.NullHandler()
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(handler)
    log.setLevel(logging.DEBUG if verbose else logging.WARNING)


# ------------------------------------------------------------------------------- main ----


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(prog="agentmux-sidebar")
    ap.add_argument("--once", action="store_true", help="render one frame to stdout and exit")
    ap.add_argument("--width", type=int)
    ap.add_argument("--height", type=int)
    ap.add_argument("--no-color", action="store_true")
    ap.add_argument("--now", type=float, help="epoch to use as 'now' (tests)")
    ap.add_argument("--input", help="tab-separated pane rows instead of tmux (tests)")
    ap.add_argument("--print-format", action="store_true")
    ap.add_argument("--density", choices=("full", "compact"))
    ap.add_argument("-L", dest="socket_name")
    ap.add_argument("-S", dest="socket_path")
    ap.add_argument("--verbose", action="store_true")
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.print_format:
        print(LIST_FORMAT)
        return 0
    setup_logging(args.verbose)
    socket_args: list[str] = []
    if args.socket_name:
        socket_args = ["-L", args.socket_name]
    elif args.socket_path:
        socket_args = ["-S", args.socket_path]
    tmux_bin = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
    tmux = Tmux(tmux_bin, socket_args)
    self_pane = os.environ.get("TMUX_PANE", "")

    if args.input:
        with open(args.input, encoding="utf-8") as fh:
            rows = parse_rows(fh.read(), sep="\t")
        theme = Theme(dict(DEFAULT_COLORS), enabled=not args.no_color)
        width = args.width or 46
        height = args.height or 24
        ttl = DEFAULT_TTL
        density = args.density or "full"
    else:
        try:
            colors, width, ttl, density = read_theme(tmux)
        except (RuntimeError, OSError, subprocess.SubprocessError) as exc:
            print(f"agentmux-sidebar: cannot reach tmux: {exc}", file=sys.stderr)
            return 1
        theme = Theme(colors, enabled=not args.no_color)
        width = args.width or width
        density = args.density or density
        height = args.height or 24
        rows = None

    if args.once:
        if rows is None:
            rows = tmux.list_panes()
        now = args.now or time.time()
        model = build_model(rows, now, self_pane, ttl)
        frame = render(model, width, height, theme, density)
        sys.stdout.write("\n".join(frame.lines) + "\n")
        return 0

    if not self_pane:
        print("agentmux-sidebar: must run inside a tmux pane ($TMUX_PANE unset)", file=sys.stderr)
        return 1
    return run_forever(tmux, self_pane, theme, ttl, density, args)


def run_forever(
    tmux: Tmux,
    self_pane: str,
    theme: Theme,
    ttl: int,
    density: str,
    args: argparse.Namespace,
) -> int:
    # Only one sidebar per server.
    try:
        other = tmux.display(f"#{{E:{OPT}sb_pane}}")
    except RuntimeError:
        other = ""
    if other and other != self_pane:
        log.warning("another sidebar exists (%s); exiting", other)
        return 0
    try:
        server_pid = tmux.display("#{pid}")
        bg = tmux.display(f"#{{{OPT}color_sidebar_bg}}") or "default"
        owner = tmux.display(f"#{{{OPT}owner}}")
        cmd = [
            "set",
            "-p",
            "-t",
            self_pane,
            OPT + "sidebar",
            "1",
            ";",
            "select-pane",
            "-d",
            "-t",
            self_pane,
            ";",
            "select-pane",
            "-T",
            SIDEBAR_TITLE,
            "-t",
            self_pane,
            ";",
            "set",
            "-p",
            "-t",
            self_pane,
            "window-style",
            f"bg={bg}",
            ";",
            "set",
            "-p",
            "-t",
            self_pane,
            "window-active-style",
            f"bg={bg}",
            ";",
            "set",
            "-g",
            OPT + "on",
            "1",
        ]
        if not owner:
            cmd += [";", "set", "-gF", OPT + "owner", "#{client_name}"]
        tmux.run(*cmd)
        # A restored sidebar (tmux-resurrect) may sit in the wrong place: let the layout
        # format settle it now rather than on the next window event.
        tmux.run("run-shell", "-C", f"#{{E:{OPT}layout}}")
    except (RuntimeError, subprocess.SubprocessError) as exc:
        log.warning("setup failed: %s", exc)

    rows_path = os.path.join(scratch_dir(server_pid), "sidebar.rows")
    term = Term()
    waker = Waker(tmux)
    reload_theme = threading.Event()

    def on_usr1(*_: object) -> None:
        reload_theme.set()
        waker.event.set()

    def on_term(*_: object) -> None:
        waker.shutdown()

    signal.signal(signal.SIGUSR1, on_usr1)
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, on_term)

    term.enter()
    waker.start()
    waker.event.set()
    full = True
    width = args.width or 0
    try:
        while waker.wait():
            if reload_theme.is_set():
                reload_theme.clear()
                try:
                    colors, _w, ttl, density = read_theme(tmux)
                    theme = Theme(colors, enabled=not args.no_color)
                    width = args.width or 0
                    full = True
                except (RuntimeError, subprocess.SubprocessError):
                    pass
            if waker.resized:
                waker.resized = False
                full = True
            try:
                size = os.get_terminal_size(term.fd)
                cols, lines = size.columns, size.lines
            except OSError:
                cols, lines = 46, 24
            cur_width = width or cols
            try:
                rows = tmux.list_panes()
            except (RuntimeError, subprocess.SubprocessError) as exc:
                log.warning("list-panes failed: %s", exc)
                if "no server" in str(exc) or "failed to connect" in str(exc):
                    break
                continue
            now = time.time()
            model = build_model(rows, now, self_pane, ttl)
            me = next((r for r in rows if r["pane_id"] == self_pane), None)
            visible = (
                bool(me) and me["window_active"] == "1" and me["session_attached"] not in ("", "0")
            )
            ticking = any(a.start for a in model.agents)
            waker.period = 1.0 if (visible and ticking) else 5.0
            if not visible:
                continue
            frame = render(model, min(cur_width, cols), lines, theme, density)
            term.draw(frame.lines, full=full)
            full = False
            try:
                os.makedirs(os.path.dirname(rows_path), exist_ok=True)
                with open(rows_path, "w", encoding="utf-8") as fh:
                    for y, target, pane_id in frame.rows:
                        fh.write(f"{y}\t{target}\t{pane_id}\n")
            except OSError:
                pass
    finally:
        waker.shutdown()
        term.leave()
        with contextlib.suppress(RuntimeError, subprocess.SubprocessError):
            tmux.run("set", "-pu", "-t", self_pane, OPT + "sidebar")
    return 0


if __name__ == "__main__":
    sys.exit(main())
