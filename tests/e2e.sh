#!/bin/sh
# End-to-end tests against real tmux servers (hermetic: private sockets, temp HOME/scratch).
#   1. Claude hook state machine on a direct pane, badge/label/timer/title formats.
#   2. Codex state machine (kind codex, Interrupt -> idle).
#   3. Attached server: an inner tmux attached from an outer pane (section 5 runs on it); its
#      agents stay on it; seen -> idle.
#   4. Omnigent hop: private -S server attached from an outer pane, state lands on the outer
#      pane; a private server with no client gets markers only.
#   5. Sidebar: toggle, follow, bounce, fix, lonely, skip, toggle off.
# shellcheck disable=SC2154,SC1010,SC2015
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

GLY_BLOCKED='󰸇'
GLY_DONE='󰄬'
GLY_DELEG='󰀐'

# ------------------------------------------------------------------ 1. claude direct ----
section "claude direct"
start_server t lap || { ko "outer server failed to start"; exit 1; }
SP=$(t display -p '#{socket_path}')
PID=$(t display -p '#{pid}')
P=$(t display -p -t lap:1 '#{pane_id}')
badge() { t display -p -t "$P" '#{E:@agentmux_badge}'; }
label() { t display -p -t "$P" '#{E:@agentmux_label}'; }
timer() { t display -p -t "$P" '#{E:@agentmux_timer}'; }

fire claude SessionStart-compact "$SP" "$PID" "$P"
assert_empty "compact SessionStart ignored" "$(opt "$P" state)"
fire claude SessionStart "$SP" "$PID" "$P"
assert_eq "SessionStart -> idle" idle "$(opt "$P" state)"
assert_eq "kind" claude "$(opt "$P" kind)"
assert_eq "project from cwd walk (no .git) = basename" src "$(opt "$P" project)"
assert_empty "start unset on idle" "$(opt "$P" start)"
assert_contains "badge idle" "·" "$(badge)"
assert_contains "label project" "src" "$(label)"
assert_contains "label kind" ":#[fg=colour245]claude" "$(label)"
assert_empty "timer empty when idle" "$(timer)"

fire claude UserPromptSubmit "$SP" "$PID" "$P"
assert_eq "UserPromptSubmit -> working" working "$(opt "$P" state)"
assert_nonempty "start set" "$(opt "$P" start)"
assert_eq "detail = prompt excerpt" "fix the flaky test in ci" "$(opt "$P" detail)"
assert_contains "badge working" "●" "$(badge)"
assert_contains "timer ticking" "m0" "$(timer)"
assert_eq "project via CLAUDE_PROJECT_DIR" demo "$(CLAUDE_PROJECT_DIR=/x/demo fire claude UserPromptSubmit "$SP" "$PID" "$P"; opt "$P" project)"

fire claude SubagentStart-a1 "$SP" "$PID" "$P"
fire claude SubagentStart-a2 "$SP" "$PID" "$P"
assert_eq "SubagentStart x2 -> working" working "$(opt "$P" state)"
assert_eq "subagents 2" 2 "$(opt "$P" subagents)"

fire claude Stop "$SP" "$PID" "$P"
assert_eq "Stop with live subagents -> delegating" delegating "$(opt "$P" state)"
assert_contains "badge delegating glyph" "$GLY_DELEG" "$(badge)"
assert_contains "badge delegating count" "${GLY_DELEG}2" "$(badge)"
assert_nonempty "timer keeps ticking while delegating" "$(timer)"

fire claude PermissionRequest "$SP" "$PID" "$P"
assert_eq "PermissionRequest -> blocked" blocked "$(opt "$P" state)"
assert_eq "blocked detail" "permission Bash" "$(opt "$P" detail)"
assert_contains "badge blocked" "$GLY_BLOCKED" "$(badge)"

# PostToolUse from a sub-agent with another id must not clear the block
fire claude PostToolUse-subagent-other "$SP" "$PID" "$P" PostToolUse
assert_eq "PostToolUse (other id, subagent) keeps blocked" blocked "$(opt "$P" state)"
fire claude PostToolUse-match "$SP" "$PID" "$P" PostToolUse
assert_eq "PostToolUse (matching id) -> delegating" delegating "$(opt "$P" state)"

# Completion hooks must run for tools that used to be excluded by Claude's matcher.
fire claude PermissionRequest-Read "$SP" "$PID" "$P"
assert_eq "Read PermissionRequest -> blocked" blocked "$(opt "$P" state)"
fire claude PostToolUse-Read-match "$SP" "$PID" "$P" PostToolUse
assert_eq "Read PostToolUse clears matching block" delegating "$(opt "$P" state)"
fire claude PermissionRequest-Read "$SP" "$PID" "$P"
fire claude PostToolUseFailure-Read-match "$SP" "$PID" "$P" PostToolUseFailure
assert_eq "Read PostToolUseFailure clears matching block" delegating "$(opt "$P" state)"

fire claude PreToolUse-AskUserQuestion "$SP" "$PID" "$P"
assert_eq "AskUserQuestion -> blocked" blocked "$(opt "$P" state)"
assert_eq "question detail" question "$(opt "$P" detail)"
fire claude PostToolUse-match "$SP" "$PID" "$P" PostToolUse
assert_eq "main-agent PostToolUse clears a stale block" delegating "$(opt "$P" state)"

fire claude SubagentStop-a1 "$SP" "$PID" "$P"
assert_eq "SubagentStop x1 -> still delegating" delegating "$(opt "$P" state)"
assert_eq "subagents 1" 1 "$(opt "$P" subagents)"
fire claude SubagentStop-a2 "$SP" "$PID" "$P"
assert_eq "last SubagentStop -> auto-resume working" working "$(opt "$P" state)"
assert_eq "detail resuming" resuming "$(opt "$P" detail)"
assert_eq "subagents 0" 0 "$(opt "$P" subagents)"

fire claude Notification-elicitation "$SP" "$PID" "$P"
assert_eq "elicitation -> blocked" blocked "$(opt "$P" state)"
fire claude PostToolUse-subagent-other "$SP" "$PID" "$P" PostToolUse
assert_eq "any PostToolUse clears an id-less block" working "$(opt "$P" state)"

fire claude Notification-idle_prompt "$SP" "$PID" "$P"
assert_eq "idle_prompt while working (missed Stop) -> done" done "$(opt "$P" state)"
assert_empty "start unset on done" "$(opt "$P" start)"
assert_contains "badge done" "$GLY_DONE" "$(badge)"
assert_empty "timer empty when done" "$(timer)"

fire claude UserPromptSubmit "$SP" "$PID" "$P"
fire claude Stop "$SP" "$PID" "$P"
assert_eq "Stop no subagents -> done (not viewed)" done "$(opt "$P" state)"

# TTL: a stale update renders idle in formats while the option still says done
t set -p -t "$P" @agentmux_updated 1
assert_contains "ttl expired renders idle" "·" "$(badge)"
t set -g @agentmux_ttl 9999999999
assert_contains "ttl raised renders done again" "$GLY_DONE" "$(badge)"
t set -g @agentmux_ttl 14400
fire claude UserPromptSubmit "$SP" "$PID" "$P"

# Shell gate: the same state on a pane whose command is a shell renders idle
P2=$(t new-window -d -P -F '#{pane_id}' -t lap:)
t set -p -t "$P2" @agentmux_state blocked \; set -p -t "$P2" @agentmux_updated "$(date +%s)"
assert_contains "shell gate hides state" "·" "$(t display -p -t "$P2" '#{E:@agentmux_badge}')"
t kill-window -t "$P2"

assert_eq "titles on by default" on "$(t show -gv set-titles)"
assert_eq "title is the human fragment" '#{E:@agentmux_title_human}' "$(t show -gv set-titles-string)"
# @agentmux_titles off hands set-titles to the user's config: a reload must not clobber it.
t set -g @agentmux_titles off \; set -g set-titles-string custom
t run-shell "$ROOT/agentmux.tmux"
assert_eq "titles off leaves set-titles-string alone" custom "$(t show -gv set-titles-string)"
t set -g @agentmux_titles on
t run-shell "$ROOT/agentmux.tmux"
assert_eq "titles on (re)claims set-titles-string" '#{E:@agentmux_title_human}' "$(t show -gv set-titles-string)"
# (window names are only auto-renamed for attached clients, so only the shape is checked)
HUMAN=$(t display -p -t "$P" '#{E:@agentmux_title_human}')
assert_contains "title_human" "lap:" "$HUMAN"
assert_not_contains "title_human quiet while working" " - agent" "$HUMAN"
assert_contains "title_human flags a blocked agent" " - agent blocked" "$(fire claude PermissionRequest "$SP" "$PID" "$P"; t display -p -t "$P" '#{E:@agentmux_title_human}')"
fire claude PostToolUse-match "$SP" "$PID" "$P" PostToolUse
SF=$(t display -p -t "$P" '#{T:window-status-format}')
assert_contains "status format renders badge" "●" "$SF"
assert_contains "status format renders label" "src" "$SF"

fire claude SessionEnd "$SP" "$PID" "$P"
assert_empty "SessionEnd unsets state" "$(opt "$P" state)"
assert_empty "SessionEnd unsets kind" "$(opt "$P" kind)"
assert_empty "SessionEnd unsets project" "$(opt "$P" project)"
[ -d "$XDG_RUNTIME_DIR/agentmux-${USER:-u}/$PID/${P#%}" ] && ko "scratch dir wiped on SessionEnd" || ok

# ------------------------------------------------------------------ 2. codex ----
section "codex"
fire codex SessionStart "$SP" "$PID" "$P"
assert_eq "codex idle" idle "$(opt "$P" state)"
assert_eq "codex kind" codex "$(opt "$P" kind)"
fire codex UserPromptSubmit "$SP" "$PID" "$P"
assert_eq "codex working" working "$(opt "$P" state)"
fire codex PreToolUse-request_user_input "$SP" "$PID" "$P"
assert_eq "request_user_input -> blocked" blocked "$(opt "$P" state)"
fire codex PostToolUse-request_user_input "$SP" "$PID" "$P" PostToolUse
assert_eq "answered -> working" working "$(opt "$P" state)"
fire codex PermissionRequest "$SP" "$PID" "$P"
assert_eq "codex permission -> blocked" blocked "$(opt "$P" state)"
assert_eq "codex permission detail" "permission shell" "$(opt "$P" detail)"
fire codex Interrupt "$SP" "$PID" "$P"
assert_eq "Interrupt -> idle" idle "$(opt "$P" state)"
assert_empty "Interrupt clears start" "$(opt "$P" start)"
fire codex UserPromptSubmit "$SP" "$PID" "$P"
fire codex SubagentStart "$SP" "$PID" "$P"
fire codex Stop "$SP" "$PID" "$P"
assert_eq "codex delegating" delegating "$(opt "$P" state)"
fire codex SubagentStop "$SP" "$PID" "$P"
fire codex Stop "$SP" "$PID" "$P"
assert_eq "codex done" done "$(opt "$P" state)"
fire codex SessionEnd "$SP" "$PID" "$P"
assert_empty "codex SessionEnd" "$(opt "$P" state)"

# ------------------------------------------------------------------ 3. attached server ----
section "attached server (inner tmux inside an outer pane)"
OUTER=$(t new-window -d -P -F '#{pane_id}' -t lap: "unset TMUX; exec tmux -L $SOCK_IN -f $HERE/tmux.conf new -s main 'sleep 1000'")
i=0
while [ -z "$(tin show -gqv @agentmux_badge 2>/dev/null)" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
assert_nonempty "inner server up" "$(tin show -gqv @agentmux_badge 2>/dev/null)"
poll_eq "inner has one attached client" 1 tin display -p '#{session_attached}'
ISP=$(tin display -p '#{socket_path}')
IPID=$(tin display -p '#{pid}')
IP=$(tin display -p -t main:1 '#{pane_id}')
fire claude SessionStart "$ISP" "$IPID" "$IP"
fire claude UserPromptSubmit "$ISP" "$IPID" "$IP"
assert_eq "inner working" working "$(optin "$IP" state)"
# Local is local: the outer pane running the inner client shows nothing of its agents.
assert_empty "inner agent stays off the outer pane" "$(t display -p -t "$OUTER" '#{E:@agentmux_pstate}')"
assert_contains "outer tab stays idle" "·" "$(t display -p -t "$OUTER" '#{E:@agentmux_badge}')"

# seen -> idle on the attached inner server
IP2=$(tin new-window -d -P -F '#{pane_id}' -t main: 'sleep 1000')
fire claude SessionStart "$ISP" "$IPID" "$IP2"
fire claude UserPromptSubmit "$ISP" "$IPID" "$IP2"
fire claude Stop "$ISP" "$IPID" "$IP2"
assert_eq "hidden window Stop -> done" done "$(optin "$IP2" state)"
fire claude Stop "$ISP" "$IPID" "$IP"
assert_eq "viewed window Stop -> idle directly" idle "$(optin "$IP" state)"
tin select-window -t main:2
poll_eq "viewing the done window flips it idle" idle tin show -pqv -t "$IP2" @agentmux_state
tin select-window -t main:1

# ------------------------------------------------------------------ 4. omnigent hop ----
section "omnigent hop (private -S server)"
OMP=$(t new-window -d -P -F '#{pane_id}' -t lap: "unset TMUX; exec tmux -S $OM_SOCK -f /dev/null new -s main 'sleep 1000'")
i=0
while ! tom display -p '#{pid}' >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
poll_eq "private server attached" 1 tom display -p '#{session_attached}'
OPID=$(tom display -p '#{pid}')
OIP=$(tom display -p '#{pane_id}')
sleep 0.3
fire claude SessionStart "$OM_SOCK" "$OPID" "$OIP"
fire claude UserPromptSubmit "$OM_SOCK" "$OPID" "$OIP"
assert_eq "hop: state lands on the outer pane" working "$(opt "$OMP" state)"
assert_eq "hop: kind on the outer pane" claude "$(opt "$OMP" kind)"
assert_empty "hop: nothing written on the private server" "$(tom show -pqv -t "$OIP" @agentmux_state)"
[ -s "$XDG_RUNTIME_DIR/agentmux-${USER:-u}/$OPID/${OIP#%}/outer" ] && ok || ko "hop cache written"
fire claude Stop "$OM_SOCK" "$OPID" "$OIP"
assert_eq "hop: Stop -> done on the outer pane" done "$(opt "$OMP" state)"
fire claude SessionEnd "$OM_SOCK" "$OPID" "$OIP"
assert_empty "hop: SessionEnd clears the outer pane" "$(opt "$OMP" state)"

# A private server nobody is attached to (omnigent's web-only view): markers only.
tweb -f /dev/null new -d -s web 'sleep 1000'
WPID=$(tweb display -p '#{pid}')
WP=$(tweb display -p '#{pane_id}')
WDIR=$XDG_RUNTIME_DIR/agentmux-${USER:-u}/$WPID/${WP#%}
fire claude SessionStart "$WEB_SOCK" "$WPID" "$WP"
fire claude UserPromptSubmit "$WEB_SOCK" "$WPID" "$WP"
assert_eq "no client: the scratch state still advances" working "$(cat "$WDIR/state" 2>/dev/null)"
case $(cat "$WDIR/start" 2>/dev/null) in [1-9]*) ok ;; *) ko "no client: start resolves to an epoch" ;; esac
assert_empty "no client: nothing written on the private server" "$(tweb show -pqv -t "$WP" @agentmux_state)"
fire claude SessionEnd "$WEB_SOCK" "$WPID" "$WP"
[ -d "$WDIR" ] && ko "no client: SessionEnd wipes the scratch dir" || ok
tweb kill-server

# ------------------------------------------------------------------ 5. sidebar ----
section "sidebar (on the attached inner server)"
CLIENT=$(tin list-clients -F '#{client_name}')
tin run-shell "$ROOT/bin/agentmux toggle '$CLIENT'"
poll_nonempty "toggle creates a marked sidebar" tin display -p '#{E:@agentmux_sb_pane}'
SB=$got
assert_eq "sidebar is on" 1 "$(tin show -gqv @agentmux_on)"
assert_eq "sidebar owner" "$CLIENT" "$(tin show -gqv @agentmux_owner)"
poll_eq "sidebar width 46" 46 tin display -p -t "$SB" '#{pane_width}'
assert_eq "sidebar at left" 0 "$(tin display -p -t "$SB" '#{pane_left}')"
assert_eq "sidebar full height" "$(tin display -p -t "$SB" '#{window_height}')" "$(tin display -p -t "$SB" '#{pane_height}')"
assert_eq "sidebar input off" 1 "$(tin display -p -t "$SB" '#{pane_input_off}')"
assert_eq "sidebar title" agentmux-sidebar "$(tin display -p -t "$SB" '#{pane_title}')"
assert_eq "sidebar in the current window" "$(tin display -p '#{window_id}')" "$(tin display -p -t "$SB" '#{window_id}')"
assert_ne "sidebar not active" "$SB" "$(tin display -p '#{pane_id}')"
poll_eq "renderer marked itself (survives ensure)" 1 tin show -pqv -t "$SB" @agentmux_sidebar

# Hooks run in their target's context: a title change or a split in a background window must
# not drag the sidebar there (it tracks the owner's current window, not the hook's).
tin select-pane -T retitled -t "$IP2"
BGSPLIT=$(tin split-window -d -P -F '#{pane_id}' -t "$IP2" 'sleep 1000')
sleep 0.3
assert_eq "hooks for a background window leave the sidebar alone" "$(tin display -p '#{window_id}')" "$(tin display -p -t "$SB" '#{window_id}')"
tin kill-pane -t "$BGSPLIT"

tin select-window -t main:2
poll_eq "sidebar follows select-window" "$(tin display -p -t main:2 '#{window_id}')" tin display -p -t "$SB" '#{window_id}'
assert_eq "sidebar stays at left after join" 0 "$(tin display -p -t "$SB" '#{pane_left}')"
assert_eq "sidebar keeps width after join" 46 "$(tin display -p -t "$SB" '#{pane_width}')"

tin select-pane -t "$SB"
poll_eq "select-pane onto the sidebar bounces back" "$IP2" tin display -p '#{pane_id}'

tin resize-pane -t "$SB" -x 30
poll_eq "width drift is fixed" 46 tin display -p -t "$SB" '#{pane_width}'

tin resize-window -x 60 -y 20 -t main:2
sleep 0.5
tin resize-window -x 220 -y 50 -t main:2
poll_eq "narrow-then-wide keeps the sidebar at 46" 46 tin display -p -t "$SB" '#{pane_width}'

W1=$(tin display -p -t main:1 '#{window_id}')
W2=$(tin display -p -t main:2 '#{window_id}')
tin resize-pane -Z -t "$IP2"
sleep 0.3
assert_eq "zoom hides the sidebar in place" "$W2" "$(tin display -p -t "$SB" '#{window_id}')"
assert_eq "zoomed window stays zoomed" 1 "$(tin display -p -t main:2 '#{window_zoomed_flag}')"
tin select-window -t main:1
poll_eq "switching away (tmux unzooms) is followed" "$W1" tin display -p -t "$SB" '#{window_id}'
tin select-window -t main:2
poll_eq "back to window 2 is followed" "$W2" tin display -p -t "$SB" '#{window_id}'
tin resize-pane -Z -t "$IP2"
sleep 0.3
tin resize-pane -Z -t "$IP2"
poll_eq "zoom/unzoom in place keeps the sidebar" "$W2" tin display -p -t "$SB" '#{window_id}'
poll_eq "unzoom restores the width" 46 tin display -p -t "$SB" '#{pane_width}'
assert_eq "unzoom restores the left position" 0 "$(tin display -p -t "$SB" '#{pane_left}')"

# lonely: kill the only other pane in the sidebar's window (window 2 = $IP2 + sidebar). Two
# hooks race to evict the lonely sidebar; the loser must not fail the user's kill-pane.
assert_empty "killing the sidebar's last neighbour reports no error" "$(tin kill-pane -t "$IP2" 2>&1)"
poll_nonempty "lonely sidebar is replaced by a new one" sh -c "tmux -L $SOCK_IN display -p '#{E:@agentmux_sb_pane}' | grep -v '^$SB\$'"
SB2=$got
assert_eq "new sidebar in the current window" "$(tin display -p '#{window_id}')" "$(tin display -p -t "$SB2" '#{window_id}')"
poll_eq "new sidebar marked" 1 tin show -pqv -t "$SB2" @agentmux_sidebar
assert_eq "exactly one sidebar" 1 "$(tin list-panes -a -F '#{@agentmux_sidebar}' | grep -c 1)"

# Skip: @agentmux_sidebar_skip keeps the sidebar out of the owner's window while that window's
# active pane matches; @agentmux_on stays 1 so it comes back as soon as it stops matching.
tin set -g @agentmux_sidebar_skip '#{m:SKIPME*,#{pane_title}}'
SKW=$(tin display -p '#{window_id}')
SKP=$(tin display -p '#{pane_id}')
tin select-pane -T SKIPME -t "$SKP"
poll_empty "retitling the target pane evicts the sidebar" tin display -p '#{E:@agentmux_sb_pane}'
assert_eq "sidebar stays on while evicted" 1 "$(tin show -gqv @agentmux_on)"
tin select-pane -T plain -t "$SKP"
poll_nonempty "retitling it back re-creates the sidebar" tin display -p '#{E:@agentmux_sb_pane}'
assert_eq "re-created in the current window" "$SKW" "$(tin display -p -t "$got" '#{window_id}')"
poll_eq "re-created sidebar marked" 1 tin show -pqv -t "$got" @agentmux_sidebar

# The active pane decides: moving onto a skipped split evicts, moving off re-creates.
SPLIT=$(tin split-window -d -P -F '#{pane_id}' -t "$SKP" 'sleep 1000')
tin select-pane -T SKIPME -t "$SPLIT"
tin select-pane -t "$SPLIT"
poll_empty "selecting a skipped pane evicts the sidebar" tin display -p '#{E:@agentmux_sb_pane}'
tin select-pane -t "$SKP"
poll_nonempty "selecting a plain pane re-creates it" tin display -p '#{E:@agentmux_sb_pane}'
SB3=$got
tin kill-pane -t "$SPLIT"

# A skipped window is never followed into: the sidebar waits where it is.
SKW2=$(tin new-window -d -P -F '#{window_id}' -t main: 'sleep 1000')
tin select-pane -T SKIPME -t "$SKW2"
tin select-window -t "$SKW2"
sleep 0.3
assert_eq "the sidebar does not follow into a skipped window" "$SKW" "$(tin display -p -t "$SB3" '#{window_id}')"
tin select-window -t "$SKW"
tin kill-window -t "$SKW2"
tin set -gu @agentmux_sidebar_skip

tin run-shell "$ROOT/bin/agentmux toggle '$CLIENT'"
poll_empty "toggle removes the sidebar" tin display -p '#{E:@agentmux_sb_pane}'
assert_eq "sidebar off" 0 "$(tin show -gqv @agentmux_on)"
LOGF=$XDG_STATE_HOME/agentmux/sidebar.log
if [ -s "$LOGF" ]; then ko "sidebar.log not empty: $(head -3 "$LOGF")"; else ok; fi

# ------------------------------------------------------------------ summary ----
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
