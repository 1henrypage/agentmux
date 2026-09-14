#!/bin/sh
# Installer tests: idempotent merge, foreign entries preserved, uninstall clean, config.toml.
# Runs against temp CLAUDE_CONFIG_DIR / CODEX_HOME, both with jq and (if present) without.
# shellcheck disable=SC2015
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
fail=0
pass=0
ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok; else ko "$1: expected [$2] got [$3]"; fi; }
assert_grep() { if grep -q -- "$2" "$3"; then ok; else ko "$1: [$2] not found in $3"; fi; }
assert_nogrep() { if grep -q -- "$2" "$3"; then ko "$1: [$2] unexpectedly found in $3"; else ok; fi; }

run_suite() { # $1 = label, PATH already arranged
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/agentmux-install.XXXXXX")
  export CLAUDE_CONFIG_DIR="$WORK/claude" CODEX_HOME="$WORK/codex" HOME="$WORK/home"
  export TMUX_PLUGIN_MANAGER_PATH="$WORK/plugins"
  mkdir -p "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" "$HOME"
  cat >"$CLAUDE_CONFIG_DIR/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/claude-tmux-state.sh idle" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/claude-tmux-state.sh done" }, { "type": "command", "command": "say finished" } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/local/bin/lint-guard" } ] }
    ]
  },
  "statusLine": { "type": "command", "command": "~/.claude/statusline.sh", "padding": 2 },
  "editorMode": "vim"
}
EOF
  printf '[model]\nname = "gpt-5"\n' >"$CODEX_HOME/config.toml"

  # --- install (with legacy purge) ---
  "$ROOT/bin/agentmux" install-hooks --purge-legacy --hook-path /opt/agentmux/hooks/agentmux-hook >/dev/null 2>&1
  assert_eq "$1 install rc" 0 $?
  S=$CLAUDE_CONFIG_DIR/settings.json
  H=$CODEX_HOME/hooks.json
  python3 -c 'import json,sys; json.load(open(sys.argv[1])); json.load(open(sys.argv[2]))' "$S" "$H" && ok || ko "$1 valid json after install"
  assert_nogrep "$1 legacy purged" "claude-tmux-state" "$S"
  assert_grep "$1 foreign Stop hook kept" "say finished" "$S"
  assert_grep "$1 foreign PreToolUse kept" "lint-guard" "$S"
  assert_grep "$1 statusLine kept" "statusline.sh" "$S"
  assert_grep "$1 editorMode kept" '"editorMode": "vim"' "$S"
  assert_grep "$1 hook path used" "/opt/agentmux/hooks/agentmux-hook claude Stop" "$S"
  assert_eq "$1 key order preserved" "model hooks statusLine editorMode" "$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).keys()))' "$S")"
  n=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for ev in d["hooks"].values() for g in ev for h in g["hooks"] if "agentmux-hook" in h["command"]))' "$S")
  assert_eq "$1 claude entries" 11 "$n"
  n=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for ev in d["hooks"].values() for g in ev for h in g["hooks"] if "agentmux-hook" in h["command"]))' "$H")
  assert_eq "$1 codex entries" 10 "$n"
  [ -e "$S.agentmux.bak" ] && ok || ko "$1 backup created"
  assert_grep "$1 features section" '^\[features\]' "$CODEX_HOME/config.toml"
  assert_grep "$1 hooks = true" '^hooks = true' "$CODEX_HOME/config.toml"
  assert_grep "$1 model section untouched" 'name = "gpt-5"' "$CODEX_HOME/config.toml"

  # --- idempotent re-run: byte identical ---
  cp "$S" "$WORK/s1.json"; cp "$H" "$WORK/h1.json"; cp "$CODEX_HOME/config.toml" "$WORK/c1.toml"
  "$ROOT/bin/agentmux" install-hooks --purge-legacy --hook-path /opt/agentmux/hooks/agentmux-hook >/dev/null 2>&1
  cmp -s "$S" "$WORK/s1.json" && ok || ko "$1 settings idempotent"
  cmp -s "$H" "$WORK/h1.json" && ok || ko "$1 hooks.json idempotent"
  cmp -s "$CODEX_HOME/config.toml" "$WORK/c1.toml" && ok || ko "$1 config.toml idempotent"
  assert_eq "$1 features appended once" 1 "$(grep -c '^hooks = true' "$CODEX_HOME/config.toml")"

  # --- hooks = false gets flipped, existing header respected ---
  printf '[features]\nhooks = false\n\n[model]\nname = "x"\n' >"$CODEX_HOME/config.toml"
  "$ROOT/bin/agentmux" install-hooks --hook-path /opt/agentmux/hooks/agentmux-hook >/dev/null 2>&1
  assert_eq "$1 flip false->true" 'hooks = true' "$(sed -n 2p "$CODEX_HOME/config.toml")"
  assert_eq "$1 one features header" 1 "$(grep -c '^\[features\]' "$CODEX_HOME/config.toml")"
  printf '[features]\nother = 1\n[model]\nname = "x"\n' >"$CODEX_HOME/config.toml"
  "$ROOT/bin/agentmux" install-hooks --hook-path /opt/agentmux/hooks/agentmux-hook >/dev/null 2>&1
  assert_eq "$1 insert under header" 'hooks = true' "$(sed -n 3p "$CODEX_HOME/config.toml")"

  # --- symlinked settings survive in place ---
  mv "$S" "$WORK/real-settings.json"; ln -s "$WORK/real-settings.json" "$S"
  "$ROOT/bin/agentmux" uninstall-hooks >/dev/null 2>&1
  [ -L "$S" ] && ok || ko "$1 symlink preserved"
  assert_nogrep "$1 uninstall removes ours (settings)" "agentmux" "$WORK/real-settings.json"
  assert_nogrep "$1 uninstall removes ours (codex)" "agentmux" "$H"
  assert_grep "$1 uninstall keeps foreign" "say finished" "$WORK/real-settings.json"
  assert_grep "$1 uninstall keeps statusLine" "statusline.sh" "$WORK/real-settings.json"
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert "hooks" not in d, "empty hooks object must be deleted"
' "$H" && ok || ko "$1 empty hooks deleted"
  assert_grep "$1 uninstall leaves config.toml" 'hooks = true' "$CODEX_HOME/config.toml"

  # --- invalid JSON is refused ---
  printf '{not json' >"$H"
  if "$ROOT/bin/agentmux" install-hooks --hook-path /x >/dev/null 2>&1; then ko "$1 invalid json refused"; else ok; fi
  assert_eq "$1 invalid file untouched" '{not json' "$(cat "$H")"

  # --- default hook path prefers the TPM location spelled with ~ ---
  mkdir -p "$TMUX_PLUGIN_MANAGER_PATH"
  ln -s "$ROOT" "$TMUX_PLUGIN_MANAGER_PATH/agentmux"
  printf '{}\n' >"$H"
  "$ROOT/bin/agentmux" install-hooks >/dev/null 2>&1
  assert_grep "$1 tpm path" "$WORK/plugins/agentmux/hooks/agentmux-hook codex Stop" "$H"
  case $WORK in "$HOME"/*) ;; *) ok ;; esac

  rm -rf "$WORK"
}

run_suite jq
if command -v jq >/dev/null 2>&1; then
  # Hide jq to exercise the python fallback.
  NOJQ=$(mktemp -d "${TMPDIR:-/tmp}/agentmux-nojq.XXXXXX")
  for t in sh python3 mktemp cmp cp cat mv ln rm mkdir dirname awk grep sed tr head uname; do
    p=$(command -v "$t") && ln -s "$p" "$NOJQ/$t"
  done
  PATH=$NOJQ run_suite nojq
  rm -rf "$NOJQ"
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
