#!/usr/bin/env python3
"""jq-less fallback for lib/merge-hooks.jq with identical semantics.

usage: merge-hooks.py --template FILE --hook PATH --mode install|uninstall [--legacy] < settings
"""

from __future__ import annotations

import argparse
import json
import re
import sys

LEGACY = re.compile(r"claude-tmux-state\.sh")


def ours(entry: dict, legacy: bool) -> bool:
    cmd = entry.get("command", "") if isinstance(entry, dict) else ""
    if not isinstance(cmd, str):
        return False
    return "agentmux-hook" in cmd or (legacy and bool(LEGACY.search(cmd)))


def strip_ours(doc: dict, legacy: bool) -> dict:
    hooks = doc.get("hooks")
    if not isinstance(hooks, dict):
        return doc
    kept: dict = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            kept[event] = groups
            continue
        out_groups = []
        for group in groups:
            if isinstance(group, dict) and isinstance(group.get("hooks"), list):
                group = dict(group)
                group["hooks"] = [h for h in group["hooks"] if not ours(h, legacy)]
                if not group["hooks"]:
                    continue
            out_groups.append(group)
        if out_groups:
            kept[event] = out_groups
    doc["hooks"] = kept  # keep the key in place (possibly empty) so key order survives
    return doc


def prune(doc: dict) -> dict:
    if isinstance(doc.get("hooks"), dict) and not doc["hooks"]:
        del doc["hooks"]
    return doc


def template(tpl: dict, hook: str) -> dict:
    out: dict = {}
    for event, groups in tpl["hooks"].items():
        new_groups = []
        for group in groups:
            group = json.loads(json.dumps(group))
            for h in group["hooks"]:
                h["command"] = h["command"].replace("__HOOK__", hook, 1)
            new_groups.append(group)
        out[event] = new_groups
    return out


def add_ours(doc: dict, tpl: dict, hook: str) -> dict:
    hooks = doc.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
        doc["hooks"] = hooks
    for event, groups in template(tpl, hook).items():
        existing = hooks.get(event)
        if isinstance(existing, list):
            existing.extend(groups)
        else:
            hooks[event] = list(groups)
    return doc


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True)
    ap.add_argument("--hook", required=True)
    ap.add_argument("--mode", choices=("install", "uninstall"), required=True)
    ap.add_argument("--legacy", action="store_true")
    args = ap.parse_args(argv)
    doc = json.load(sys.stdin)
    if not isinstance(doc, dict):
        print("merge-hooks: top level is not an object", file=sys.stderr)
        return 1
    with open(args.template, encoding="utf-8") as fh:
        tpl = json.load(fh)
    doc = strip_ours(doc, args.legacy)
    if args.mode == "install":
        doc = add_ours(doc, tpl, args.hook)
    doc = prune(doc)
    json.dump(doc, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
