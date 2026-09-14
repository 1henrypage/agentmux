"""Decode an ssh pane's AGX1 title into @agentmux_r_* pane options (one fork per change).

Invoked by the ``pane-title-changed`` hook through ``bin/agentmux title-changed <pane>``.
The pure decision logic lives in :func:`plan` so it can be unit-tested without tmux.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from agentmux import titlecodec as tc

OPT = "@agentmux_"
SEP = "\x1f"
GRACE_MINUTES = 3


@dataclass
class Plan:
    options: dict[str, str] = field(default_factory=dict)
    notifications: list[tuple[str, str]] = field(default_factory=list)
    notified: str = ""


def plan(
    title: str,
    prev_title: str,
    prev_notified: str,
    viewed: bool,
    local_host: str,
    seen: bool,
    prev_done: str,
    now: float,
    notify_blocked: bool = True,
    notify_done: bool = True,
) -> Plan | None:
    """Decide the option writes and notifications for a new title. None = nothing to do."""
    if title == prev_title:
        return None
    decoded = tc.decode(title)
    if decoded is None:
        return None
    entries = [e for e in decoded.entries if e.host != local_host]
    old = tc.decode(prev_title) if prev_title else None
    old_by_key = {e.key: e for e in old.entries} if old else {}

    worst = "idle"
    worst2 = "idle"
    worst_entry: tc.Entry | None = None
    for e in entries:
        if tc.PRIORITY[e.state] < tc.PRIORITY[worst]:
            worst = e.state
            worst_entry = e
        if e.state != "done" and tc.PRIORITY[e.state] < tc.PRIORITY[worst2]:
            worst2 = e.state
    if worst_entry is None and entries:
        worst_entry = entries[0]
    deleg = next((str(e.subagents) for e in entries if e.state == "delegating"), "")
    done_keys = sorted(f"{e.host}:{e.target}" for e in entries if e.state == "done")
    old_done = set(prev_done.split()) if prev_done else set()
    keep_seen = seen and set(done_keys) <= old_done

    expiry = decoded.header.expiry(now, GRACE_MINUTES)
    label_entry = worst_entry
    # For the tab: when seen, the label follows the worst non-done entry if any.
    if keep_seen and worst == "done":
        label_entry = next(
            (e for e in entries if e.state == worst2 and e.state != "done"), worst_entry
        )
    out = Plan()
    out.options = {
        "r_host": decoded.header.host,
        "r_n": str(len(entries)),
        "r_worst": worst,
        "r_worst2": worst2,
        "r_deleg": deleg,
        "r_proj": label_entry.project if label_entry else "",
        "r_kind": label_entry.kind if label_entry else "",
        "r_start": str(label_entry.start or "")
        if label_entry and label_entry.state in ("working", "delegating", "blocked")
        else "",
        "r_exp": str(expiry) if expiry else "0",
        "r_seen": "1" if keep_seen else "",
        "r_done": " ".join(done_keys),
        "r_prev": title,
    }
    out.notified = prev_notified
    if not viewed and decoded.header.fresh(now, GRACE_MINUTES):
        for e in entries:
            before = old_by_key.get(e.key)
            before_state = before.state if before else "idle"
            stamp = f"{e.host}|{e.target}|{e.start}|{e.state}|{e.updated}"
            if stamp == prev_notified:
                continue
            where = f"{e.project or 'agent'} on {e.host}"
            if notify_blocked and e.state == "blocked" and before_state != "blocked":
                out.notifications.append((where, f"{where} needs you: {e.detail}".rstrip(": ")))
                out.notified = stamp
            elif (
                notify_done
                and e.state == "done"
                and before_state in ("working", "delegating", "blocked")
            ):
                out.notifications.append((where, f"{where} is done"))
                out.notified = stamp
    out.options["r_notified"] = out.notified
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: title_changed.py <pane-id>", file=sys.stderr)
        return 2
    pane = argv[0]
    tmux = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
    fields = (
        "#{pane_title}",
        f"#{{{OPT}r_prev}}",
        f"#{{{OPT}r_notified}}",
        "#{window_active}",
        "#{session_attached}",
        f"#{{?#{{{OPT}hostname}},#{{{OPT}hostname}},#{{host_short}}}}",
        f"#{{{OPT}r_seen}}",
        f"#{{{OPT}r_done}}",
        f"#{{{OPT}notify}}",
        f"#{{{OPT}notify_done}}",
    )
    try:
        raw = subprocess.run(
            [
                tmux,
                "display",
                "-p",
                "-t",
                pane,
                SEP.join(fields),
                ";",
                "list-clients",
                "-F",
                "#{?client_control_mode,,#{client_name}}",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.rstrip("\n")
    except (subprocess.SubprocessError, OSError):
        return 0
    lines = raw.split("\n")
    parts = lines[0].split(SEP)
    clients = [c for c in lines[1:] if c]
    if len(parts) != len(fields):
        return 0
    title, prev, notified, wact, satt, host, seen, prev_done, n_on, nd_on = parts
    result = plan(
        title,
        prev,
        notified,
        viewed=(wact == "1" and satt not in ("", "0")),
        local_host=host,
        seen=seen == "1",
        prev_done=prev_done,
        now=time.time(),
        notify_blocked=n_on != "off",
        notify_done=nd_on != "off",
    )
    if result is None:
        return 0
    cmd = [tmux]
    for k, v in result.options.items():
        cmd += ["set", "-p", "-t", pane, OPT + k, v, ";"]
    for c in clients:
        cmd += ["refresh-client", "-S", "-t", c, ";"]
    cmd += ["wait-for", "-S", "agentmux-redraw"]
    subprocess.run(cmd, check=False, capture_output=True, timeout=5)
    notify = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "agentmux")
    for title_, body in result.notifications:
        subprocess.Popen(
            [notify, "notify", title_, body],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
