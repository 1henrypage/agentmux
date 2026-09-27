#!/usr/bin/env python3
"""Pure tmux ``#{window_layout}`` string surgery. No tmux calls in this module.

Grammar: ``csum,WxH,X,Y`` then either ``,<pane-id>`` (leaf), ``{...}`` (left-right
children) or ``[...]`` (top-bottom children), children comma-separated. The checksum is a
16-bit rotate-right-then-add over everything after the ``csum,`` prefix (see :func:`checksum`).

Used by ``bin/agentmux`` to give back the columns the sidebar borrowed from a window's other
panes: see docs/CONTRACT.md ("Sidebar placement" / "Window options").

FOOTGUN: ``select-layout`` ignores the pane ids in a layout string and fills its cells with
the window's panes in pane-list order. :func:`main` therefore refuses a result whose leaves
are not in that order rather than let tmux shuffle panes between cells.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field


@dataclass
class Cell:
    w: int
    h: int
    x: int
    y: int
    pane_id: int | None = None
    kind: str | None = None  # "h" ({} left-right) or "v" ([] top-bottom); None for a leaf
    children: list[Cell] = field(default_factory=list)


# ------------------------------------------------------------------------------ parse ----

_DIMS = re.compile(r"(\d+)x(\d+),(\d+),(\d+)")
_DIGITS = re.compile(r"\d+")


def _parse_cell(s: str, i: int) -> tuple[Cell, int]:
    m = _DIMS.match(s, i)
    if not m:
        raise ValueError(f"malformed layout at {i}: {s[i : i + 30]!r}")
    w, h, x, y = (int(g) for g in m.groups())
    i = m.end()
    if i < len(s) and s[i] == ",":
        m2 = _DIGITS.match(s, i + 1)
        if not m2:
            raise ValueError(f"malformed pane id at {i}: {s[i : i + 30]!r}")
        return Cell(w, h, x, y, pane_id=int(m2.group())), m2.end()
    if i < len(s) and s[i] in "{[":
        kind = "h" if s[i] == "{" else "v"
        close = "}" if kind == "h" else "]"
        i += 1
        children = []
        while True:
            child, i = _parse_cell(s, i)
            children.append(child)
            if i < len(s) and s[i] == ",":
                i += 1
                continue
            break
        if i >= len(s) or s[i] != close:
            raise ValueError(f"expected {close!r} at {i}: {s[i : i + 30]!r}")
        return Cell(w, h, x, y, kind=kind, children=children), i + 1
    raise ValueError(f"malformed layout at {i}: {s[i : i + 30]!r}")


def parse(s: str) -> Cell:
    """Parse a full ``#{window_layout}`` string (checksum included)."""
    _, _, rest = s.partition(",")
    if not rest:
        raise ValueError(f"not a layout string: {s!r}")
    cell, i = _parse_cell(rest, 0)
    if i != len(rest):
        raise ValueError(f"trailing data in layout string: {rest[i:]!r}")
    return cell


# --------------------------------------------------------------------------- serialize ----


def checksum(body: str) -> int:
    """tmux's ``layout_checksum``: 16-bit rotate-right-then-add over ``body``."""
    csum = 0
    for ch in body:
        csum = (csum >> 1) + ((csum & 1) << 15)
        csum = (csum + ord(ch)) & 0xFFFF
    return csum


def _serialize_cell(cell: Cell) -> str:
    dims = f"{cell.w}x{cell.h},{cell.x},{cell.y}"
    if cell.pane_id is not None:
        return f"{dims},{cell.pane_id}"
    opening, closing = ("{", "}") if cell.kind == "h" else ("[", "]")
    return dims + opening + ",".join(_serialize_cell(c) for c in cell.children) + closing


def serialize(cell: Cell) -> str:
    body = _serialize_cell(cell)
    return f"{checksum(body):04x},{body}"


# -------------------------------------------------------------------------- geometry ----


def _recompute_sizes(cell: Cell) -> None:
    """Bottom-up: a container's size follows from its (already-fixed) children."""
    if cell.pane_id is not None:
        return
    for c in cell.children:
        _recompute_sizes(c)
    if cell.kind == "h":
        cell.w = sum(c.w for c in cell.children) + len(cell.children) - 1
        cell.h = cell.children[0].h
    else:
        cell.h = sum(c.h for c in cell.children) + len(cell.children) - 1
        cell.w = cell.children[0].w


def _fix_offsets(cell: Cell) -> None:
    """Top-down: cell.x/cell.y are correct; derive children's offsets and shared dimension."""
    if cell.pane_id is not None:
        return
    if cell.kind == "h":
        x = cell.x
        for c in cell.children:
            c.x, c.y, c.h = x, cell.y, cell.h
            x += c.w + 1
    else:
        y = cell.y
        for c in cell.children:
            c.y, c.x, c.w = y, cell.x, cell.w
            y += c.h + 1
    for c in cell.children:
        _fix_offsets(c)


# ----------------------------------------------------------------------------- strip ----


def _prune(cell: Cell, keep_ids: set[int]) -> Cell | None:
    # Copies every node it keeps: strip() resizes the result in place, and must not reach
    # back into the caller's tree.
    if cell.pane_id is not None:
        if cell.pane_id not in keep_ids:
            return None
        return Cell(cell.w, cell.h, cell.x, cell.y, pane_id=cell.pane_id)
    children = [p for c in cell.children if (p := _prune(c, keep_ids)) is not None]
    if not children:
        return None
    if len(children) == 1:
        return children[0]
    return Cell(cell.w, cell.h, cell.x, cell.y, kind=cell.kind, children=children)


def strip(cell: Cell, keep_ids: set[int]) -> Cell | None:
    """Drop leaves not in ``keep_ids``, collapse single-child nodes, resize bottom-up."""
    pruned = _prune(cell, keep_ids)
    if pruned is None:
        return None
    pruned.x, pruned.y = cell.x, cell.y
    _recompute_sizes(pruned)
    _fix_offsets(pruned)
    return pruned


# -------------------------------------------------------------------------- borrowed ----


def borrowed(clean: Cell, sq0: Cell) -> Cell | None:
    """Per-cell ``(dw, dh)`` lent by ``clean`` to become ``sq0``; ``None`` if not isomorphic."""
    if clean.pane_id is not None or sq0.pane_id is not None:
        if clean.pane_id != sq0.pane_id:
            return None
        return Cell(clean.w - sq0.w, clean.h - sq0.h, 0, 0, pane_id=clean.pane_id)
    if clean.kind != sq0.kind or len(clean.children) != len(sq0.children):
        return None
    children = []
    for a, b in zip(clean.children, sq0.children):
        d = borrowed(a, b)
        if d is None:
            return None
        children.append(d)
    return Cell(clean.w - sq0.w, clean.h - sq0.h, 0, 0, kind=clean.kind, children=children)


# -------------------------------------------------------------------------- give_back ----


def _apply_delta(sq: Cell, delta: Cell) -> Cell | None:
    if sq.pane_id is not None or delta.pane_id is not None:
        if sq.pane_id != delta.pane_id:
            return None
        return Cell(sq.w + delta.w, sq.h + delta.h, sq.x, sq.y, pane_id=sq.pane_id)
    if sq.kind != delta.kind or len(sq.children) != len(delta.children):
        return None
    children = []
    for cs, cd in zip(sq.children, delta.children):
        r = _apply_delta(cs, cd)
        if r is None:
            return None
        children.append(r)
    return Cell(sq.w + delta.w, sq.h + delta.h, sq.x, sq.y, kind=sq.kind, children=children)


def give_back(sq: Cell, delta: Cell) -> Cell | None:
    """Add each cell's lent ``(dw, dh)`` back onto ``sq``; ``None`` if not isomorphic."""
    result = _apply_delta(sq, delta)
    if result is None:
        return None
    _fix_offsets(result)
    return result


# ----------------------------------------------------------------------------- expand ----


def _scale(sizes: list[int], total: int) -> list[int]:
    """``sizes`` scaled to sum to ``total`` at the same ratio, each at least 1.

    Largest remainder: every size gets the floor of its exact share, and the cells whose
    share lost the most to that floor get the leftover units, one each.
    """
    n = len(sizes)
    weights = sizes if sum(sizes) > 0 else [1] * n
    old_total = sum(weights)
    shares = [divmod(w * total, old_total) for w in weights]
    out = [q for q, _ in shares]
    leftover = total - sum(out)
    for i in sorted(range(n), key=lambda i: shares[i][1], reverse=True)[:leftover]:
        out[i] += 1
    # A share can floor to 0 only when shrinking: take its unit from the widest cell.
    for i in range(n):
        if out[i] < 1:
            widest = max(range(n), key=out.__getitem__)
            if out[widest] <= 1:
                break
            out[widest] -= 1
            out[i] += 1
    return out


def _expand_sizes(cell: Cell, sx: int, sy: int) -> Cell:
    if cell.pane_id is not None:
        return Cell(sx, sy, cell.x, cell.y, pane_id=cell.pane_id)
    if cell.kind == "h":
        widths = _scale([c.w for c in cell.children], sx - len(cell.children) + 1)
        children = [_expand_sizes(c, w, sy) for c, w in zip(cell.children, widths)]
    else:
        heights = _scale([c.h for c in cell.children], sy - len(cell.children) + 1)
        children = [_expand_sizes(c, sx, h) for c, h in zip(cell.children, heights)]
    return Cell(sx, sy, cell.x, cell.y, kind=cell.kind, children=children)


def expand(cell: Cell, sx: int, sy: int) -> Cell:
    """Fallback: scale ``cell``'s children proportionally to fill ``sx`` x ``sy``."""
    result = _expand_sizes(cell, sx, sy)
    _fix_offsets(result)
    return result


# ------------------------------------------------------------------------------- main ----


def leaf_ids(cell: Cell) -> list[int]:
    """Pane ids in layout order, the order ``select-layout`` fills cells in."""
    if cell.pane_id is not None:
        return [cell.pane_id]
    return [i for c in cell.children for i in leaf_ids(c)]


def relayout(clean_s: str, sq0_s: str, sq_s: str, pane_ids: list[int]) -> Cell | None:
    """The layout that gives a window back what it lent the sidebar.

    ``clean_s``/``sq0_s`` are the window's layout right before/after the sidebar arrived
    (either may be empty), ``sq_s`` its layout right before the sidebar left, ``pane_ids``
    the panes left in it, in pane-list order. The give-back is exact when the window's
    panes still split the same way as when the sidebar arrived; otherwise the panes are
    scaled up proportionally. Either way the result fills the window ``sq_s`` was taken
    at. ``None`` when there is nothing ``select-layout`` could apply safely.
    """
    try:
        sq = parse(sq_s)
    except ValueError:
        return None
    sq_stripped = strip(sq, set(pane_ids))
    if sq_stripped is None:
        return None

    result = None
    if clean_s and sq0_s:
        try:
            clean, sq0 = parse(clean_s), parse(sq0_s)
        except ValueError:
            clean = sq0 = None
        sq0_stripped = strip(sq0, set(pane_ids)) if sq0 is not None else None
        if clean is not None and sq0_stripped is not None:
            delta = borrowed(clean, sq0_stripped)
            if delta is not None:
                result = give_back(sq_stripped, delta)
    if result is None:
        result = expand(sq_stripped, sq.w, sq.h)
    elif (result.w, result.h) != (sq.w, sq.h):
        # The sidebar was resized while it was here (a new @agentmux_width, a window too
        # narrow for the full width), so what each pane lent no longer adds up to the room
        # it leaves: fit the give-back to the window.
        result = expand(result, sq.w, sq.h)

    if leaf_ids(result) != pane_ids:
        return None
    return result


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        print("usage: relayout.py CLEAN SQ0 SQ PANE_IDS", file=sys.stderr)
        return 1
    clean_s, sq0_s, sq_s, ids_s = argv[1:]
    try:
        pane_ids = [int(p.removeprefix("%")) for p in ids_s.split(",") if p]
    except ValueError:
        return 1
    result = relayout(clean_s, sq0_s, sq_s, pane_ids)
    if result is None:
        return 1
    print(serialize(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
