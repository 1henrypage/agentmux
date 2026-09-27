#!/bin/sh
# Shared helpers for tests/e2e.sh. Sourced, not executed.
# shellcheck disable=SC2034
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
FIX=$HERE/fixtures/payloads
HOOK=$ROOT/hooks/agentmux-hook

pass=0
fail=0
ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); printf '\033[31mFAIL\033[0m %s\n' "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok; else ko "$1: expected [$2] got [$3]"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then ok; else ko "$1: expected anything but [$2]"; fi; }
assert_contains() { case $3 in *"$2"*) ok ;; *) ko "$1: [$2] not in [$3]" ;; esac; }
assert_not_contains() { case $3 in *"$2"*) ko "$1: [$2] unexpectedly in [$3]" ;; *) ok ;; esac; }
assert_empty() { if [ -z "$2" ]; then ok; else ko "$1: expected empty, got [$2]"; fi; }
assert_nonempty() { if [ -n "$2" ]; then ok; else ko "$1: expected a value"; fi; }
section() { printf '\n== %s\n' "$1"; }

# poll_eq NAME EXPECTED CMD... : re-run CMD up to ~5 s until its output equals EXPECTED.
poll_eq() {
  name=$1 expect=$2
  shift 2
  i=0
  while [ $i -lt 50 ]; do
    got=$("$@" 2>/dev/null)
    [ "$got" = "$expect" ] && { ok; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  ko "$name: expected [$expect] got [$got] (after 5 s)"
  return 1
}
# poll_nonempty NAME CMD... -> sets $got
poll_nonempty() {
  name=$1
  shift
  i=0
  while [ $i -lt 50 ]; do
    got=$("$@" 2>/dev/null)
    [ -n "$got" ] && { ok; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  ko "$name: still empty after 5 s"
  return 1
}
poll_empty() {
  name=$1
  shift
  i=0
  while [ $i -lt 50 ]; do
    got=$("$@" 2>/dev/null)
    [ -z "$got" ] && { ok; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  ko "$name: still [$got] after 5 s"
  return 1
}

# Hermetic environment.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/agentmux-e2e.XXXXXX")
export TMUX_TMPDIR="$WORK"
export HOME="$WORK/home"
export XDG_STATE_HOME="$WORK/state"
export XDG_RUNTIME_DIR="$WORK/run"
export CLAUDE_CONFIG_DIR="$WORK/claude"
export CODEX_HOME="$WORK/codex"
export AGENTMUX_DIR="$ROOT"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
unset TMUX TMUX_PANE CLAUDE_PROJECT_DIR
SOCK=agx-e2e-$$
SOCK_IN=agx-in-$$
OM_SOCK=$WORK/om.sock
WEB_SOCK=$WORK/web.sock
t() { tmux -L "$SOCK" "$@"; }
tin() { tmux -L "$SOCK_IN" "$@"; }
tom() { tmux -S "$OM_SOCK" "$@"; }
tweb() { tmux -S "$WEB_SOCK" "$@"; }
cleanup() {
  t kill-server 2>/dev/null
  tin kill-server 2>/dev/null
  tom kill-server 2>/dev/null
  tweb kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# opt PANE NAME (via t) ; optin PANE NAME (via tin)
opt() { t show -pqv -t "$1" "@agentmux_$2" 2>/dev/null; }
optin() { tin show -pqv -t "$1" "@agentmux_$2" 2>/dev/null; }
# fire KIND FIXTURE SOCKPATH PID PANE [EVENT-HINT]
fire() {
  TMUX="$3,$4,0" TMUX_PANE=$5 "$HOOK" "$1" "${6:-}" <"$FIX/$1/$2.json"
}
start_server() { # tmux-fn session-name
  fn=$1 name=$2
  "$fn" -f "$HERE/tmux.conf" new -d -s "$name" -x 220 -y 50 'sleep 1000' || return 1
  i=0
  while [ -z "$("$fn" show -gqv @agentmux_badge 2>/dev/null)" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -n "$("$fn" show -gqv @agentmux_badge 2>/dev/null)" ]
}
