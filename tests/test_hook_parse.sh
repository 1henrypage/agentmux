#!/bin/sh
# Unit tests for the pure parts of hooks/agentmux-hook: jget, san, derive, constants.
# Sources the hook with AGENTMUX_HOOK_LIB=1 so main() does not run.
# shellcheck disable=SC2154,SC2034,SC1010,SC2015
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
fail=0
pass=0

ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok; else ko "$1: expected [$2] got [$3]"; fi
}

AGENTMUX_HOOK_LIB=1
export AGENTMUX_HOOK_LIB
# shellcheck source=hooks/agentmux-hook
. "$ROOT/hooks/agentmux-hook"
# shellcheck source=lib/constants.sh
. "$ROOT/lib/constants.sh"

# --- constants agree between the hook and lib/constants.sh -------------------------------
assert_eq "opt prefix" "$AGENTMUX_OPT" "$AGX_OPT"
assert_eq "magic" "$AGENTMUX_MAGIC" "$AGX_MAGIC"
assert_eq "san max" "$AGENTMUX_SAN_MAX" "$AGX_SAN_MAX"
assert_eq "redraw channel" "$AGENTMUX_REDRAW_CHANNEL" "$AGX_REDRAW"

# --- jget on compact JSON ------------------------------------------------------------------
jq_bin=$(command -v jq 2>/dev/null || true)
input=$(cat "$HERE/fixtures/payloads/claude/PermissionRequest.json")
jget hook_event_name; assert_eq "event" PermissionRequest "$v"
jget tool_name; assert_eq "tool_name" Bash "$v"
jget tool_use_id; assert_eq "tool_use_id after tool_input" toolu_perm_1 "$v"
jget cwd; assert_eq "cwd" /Users/x/projects/demo/src "$v"
jget agent_id; assert_eq "missing key is empty" "" "$v"
jget nope; assert_eq "missing key rc" "" "$v"

input='{"a":true,"n":12,"z":null,"s":"x"}'
jget a; assert_eq "bool" true "$v"
jget n; assert_eq "number" 12 "$v"
jget z; assert_eq "null" "" "$v"
jget s; assert_eq "last string" x "$v"

# --- jget on pretty JSON with escapes -------------------------------------------------------
input=$(tr -d '\n' <"$HERE/fixtures/payloads/claude/UserPromptSubmit-pretty.json")
jget hook_event_name; assert_eq "pretty event" UserPromptSubmit "$v"
jget prompt
case $v in
'say "hi" \ then stop' | 'say "hi" \ then
stop') ok ;;
*) ko "escaped prompt: got [$v]" ;;
esac
# without jq the fallback decoder must produce the same
saved_jq=$jq_bin
jq_bin=""
jget prompt; assert_eq "escaped prompt (no jq)" 'say "hi" \ then stop' "$v"
jq_bin=$saved_jq

# --- san -----------------------------------------------------------------------------------
san "hello world/foo"; assert_eq "san spaces+slash" hello_world_foo "$san_out"
san "  weird  ++name  "; assert_eq "san collapse" weird_name "$san_out"
san "abcdefghijklmnopqrstuvwxyz0123"; assert_eq "san truncate" abcdefghijklmnopqrstuvwx "$san_out"
san "fix the flaky test in ci, then run it twice" 24 sp; assert_eq "san prompt excerpt" "fix the flaky test in ci" "$san_out"
san "ünïcode"; assert_eq "san non-ascii" "n_code" "$san_out"
san ""; assert_eq "san empty" "" "$san_out"

# --- derive on a scratch dir -------------------------------------------------------------
dir=$(mktemp -d "${TMPDIR:-/tmp}/agentmux-test.XXXXXX")
mkdir -p "$dir/subs"
gen=1
put main stopped; clear_file blocked; clear_file start
derive; assert_eq "derive idle" idle "$state"
put start 123
derive; assert_eq "derive done" done "$state"
put main running
derive; assert_eq "derive working" working "$state"
put main stopped
printf '' >"$dir/subs/1.a.s"
derive; assert_eq "derive delegating" delegating "$state"
assert_eq "live count" 1 "$live"
printf '' >"$dir/subs/1.a.e"
derive; assert_eq "derive done after subagent end" done "$state"
put blocked "permission Bash|Bash|id"
derive; assert_eq "derive blocked" blocked "$state"
gen=2
derive; assert_eq "subs scoped by gen" 0 "$live"
rm -rf "$dir"

is_shell zsh && ok || ko "is_shell zsh"
is_shell -bash && ok || ko "is_shell -bash"
is_shell claude && ko "is_shell claude" || ok
is_shell Python && ko "is_shell Python" || ok

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
