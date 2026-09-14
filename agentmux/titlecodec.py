"""AGX1 title channel: encode/decode agent state packed into an OSC 2 window title.

Grammar (printable ASCII only; ``| ~ ; # % ,`` never appear inside data)::

    AGX1|h=<host>|t=<epoch/60>|hb=<60|0>~ ( ENTRY ~ )*
    ENTRY := h=<host>|s=<state>|k=<kind>|p=<project>|b=<start>|n=<subs>|u=<updated>
             |x=<0|1>|w=<session:window.pane>|d=<detail>

Every entry is terminated by ``~``. A trailing segment without its ``~`` is a truncated
entry (tmux caps the title with ``#{=1800:...}``) and is dropped. Unknown keys are ignored
so the grammar can grow. ``hb`` is the writer's heartbeat period in seconds: 60 for a tmux
server re-emitting its title every minute, 0 for a one-shot writer (the bare-ssh hook).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

MAGIC = "AGX1"
STATES = ("blocked", "done", "delegating", "working", "idle")
PRIORITY = {s: i for i, s in enumerate(STATES)}
MAX_DETAIL = 32
MAX_PROJECT = 24

_SAFE = re.compile(r"[^A-Za-z0-9 ._@+()-]")
_SAFE_TARGET = re.compile(r"[^A-Za-z0-9:._-]")
_ENTRY_KEYS = ("h", "s", "k", "p", "b", "n", "u", "x", "w", "d")


def sanitize(text: str, limit: int) -> str:
    """Map anything outside ``[A-Za-z0-9 ._@+()-]`` to ``_`` and cap the length."""
    return _SAFE.sub("_", text or "")[:limit]


def sanitize_target(text: str, limit: int = 64) -> str:
    """Targets (``session:window.pane``) keep ``:`` and drop everything else unsafe."""
    return _SAFE_TARGET.sub("_", text or "")[:limit]


def _int(value: str, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


@dataclass
class Entry:
    host: str = ""
    state: str = "idle"
    kind: str = ""
    project: str = ""
    start: int = 0
    subagents: int = 0
    updated: int = 0
    visible: bool = False
    target: str = ""
    detail: str = ""

    @property
    def key(self) -> tuple[str, str]:
        """Identity of an agent across title updates: (host, target)."""
        return (self.host, self.target)

    @property
    def priority(self) -> int:
        return PRIORITY.get(self.state, len(STATES))

    def encode(self) -> str:
        return "|".join(
            (
                f"h={sanitize(self.host, 64)}",
                f"s={self.state if self.state in STATES else 'idle'}",
                f"k={sanitize(self.kind, 16)}",
                f"p={sanitize(self.project, MAX_PROJECT)}",
                f"b={self.start or ''}",
                f"n={self.subagents}",
                f"u={self.updated or ''}",
                f"x={1 if self.visible else 0}",
                f"w={sanitize_target(self.target)}",
                f"d={sanitize(self.detail, MAX_DETAIL)}",
            )
        )


@dataclass
class Header:
    host: str = ""
    minute: int = 0
    heartbeat: int = 0

    def encode(self) -> str:
        return f"{MAGIC}|h={sanitize(self.host, 64)}|t={self.minute}|hb={self.heartbeat}"

    def fresh(self, now: float, grace_minutes: int = 3) -> bool:
        """A heartbeat writer is fresh for ``grace_minutes`` past its stamp; one-shot always."""
        if self.heartbeat == 0:
            return True
        return int(now) // 60 - self.minute <= grace_minutes

    def expiry(self, now: float, grace_minutes: int = 3) -> int:
        """Epoch after which entries are stale, 0 for a one-shot writer (never expires)."""
        if self.heartbeat == 0:
            return 0
        return int(now) + grace_minutes * 60


@dataclass
class Title:
    header: Header = field(default_factory=Header)
    entries: list[Entry] = field(default_factory=list)

    def encode(self) -> str:
        parts = [self.header.encode()]
        parts.extend(e.encode() for e in self.entries)
        return "~".join(parts) + "~"

    def worst(self, include_done: bool = True) -> str:
        best = "idle"
        for e in self.entries:
            if not include_done and e.state == "done":
                continue
            if PRIORITY.get(e.state, 99) < PRIORITY.get(best, 99):
                best = e.state
        return best


def is_title(text: str) -> bool:
    return bool(text) and text.startswith(MAGIC + "|")


def _kv(segment: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for piece in segment.split("|"):
        if "=" in piece:
            k, v = piece.split("=", 1)
            out.setdefault(k, v)
    return out


def decode(text: str) -> Title | None:
    """Decode a title. Returns None when ``text`` is not an AGX1 title at all."""
    if not is_title(text):
        return None
    segments = text.split("~")
    # The last split piece is either "" (title ended with ~) or a truncated entry.
    segments = segments[:-1]
    if not segments:
        return None
    head = _kv(segments[0][len(MAGIC) + 1 :])
    header = Header(
        host=head.get("h", ""),
        minute=_int(head.get("t", "")),
        heartbeat=_int(head.get("hb", "")),
    )
    entries: list[Entry] = []
    for seg in segments[1:]:
        if not seg:
            continue
        kv = _kv(seg)
        if "s" not in kv or "h" not in kv:
            continue
        state = kv.get("s", "idle")
        entries.append(
            Entry(
                host=kv.get("h", ""),
                state=state if state in STATES else "idle",
                kind=kv.get("k", ""),
                project=kv.get("p", ""),
                start=_int(kv.get("b", "")),
                subagents=_int(kv.get("n", "")),
                updated=_int(kv.get("u", "")),
                visible=kv.get("x", "0") == "1",
                target=kv.get("w", ""),
                detail=kv.get("d", ""),
            )
        )
    return Title(header=header, entries=entries)


def encode(header: Header, entries: list[Entry]) -> str:
    return Title(header, entries).encode()


def strip_header(text: str) -> str:
    """The entries part of a title (what a nesting server re-embeds verbatim)."""
    if not is_title(text):
        return ""
    idx = text.find("~")
    return "" if idx < 0 else text[idx + 1 :]
