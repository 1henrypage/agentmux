#!/bin/sh
# End-to-end tests against real tmux servers (hermetic: private sockets, temp HOME/scratch).
#   1. Claude hook state machine on a direct pane, badge/label/timer formats.
#   2. Codex state machine (kind codex, Interrupt -> idle).
#   3. Nesting: inner tmux attached from an outer pane emits an AGX1 title, outer decodes it,
#      re-embeds it, the sidebar lists the remote host; seen -> idle on the attached inner.
#   4. Omnigent hop: private -S server attached from an outer pane, state lands on the outer pane.
#   5. Sidebar: toggle, follow, bounce, fix, lonely, toggle off.
# shellcheck disable=SC2154,SC1010,SC2015
set -u
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

GLY_BLOCKED='󰸇'
GLY_DONE='󰄬'
GLY_DELEG='󰀐'
GLY_REMOTE='󰐠'
HOST=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)

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

TITLE=$(t display -p '#{E:@agentmux_title_enc}')
assert_contains "title_enc header" "AGX1|h=$HOST|t=" "$TITLE"
assert_contains "title_enc entry" "|s=working|k=claude|p=src|" "$TITLE"
assert_contains "title_enc target" "|w=lap:1.1|" "$TITLE"
assert_not_contains "title_enc has no semicolon" ";" "$TITLE"
assert_not_contains "title_enc has no hash" "#" "$TITLE"
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

# ------------------------------------------------------------------ 3. nesting ----
section "nesting (inner tmux inside an outer pane)"
OUTER=$(t new-window -d -P -F '#{pane_id}' -t lap: "unset TMUX; exec tmux -L $SOCK_IN -f $HERE/tmux.conf new -s main 'sleep 1000'")
i=0
while [ -z "$(tin show -gqv @agentmux_badge 2>/dev/null)" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
assert_nonempty "inner server up" "$(tin show -gqv @agentmux_badge 2>/dev/null)"
# Both servers run on this machine; give the inner one its own name so the outer's self-echo
# filter (entries from the local host are dropped) does not hide it.
tin set -g @agentmux_hostname devbox
RHOST=devbox
poll_eq "inner has one attached client" 1 tin display -p '#{session_attached}'
assert_eq "inner client is a tmux terminal" tmux-256color "$(tin list-clients -F '#{client_termname}')"
ISP=$(tin display -p '#{socket_path}')
IPID=$(tin display -p '#{pid}')
IP=$(tin display -p -t main:1 '#{pane_id}')
fire claude SessionStart "$ISP" "$IPID" "$IP"
fire claude UserPromptSubmit "$ISP" "$IPID" "$IP"
assert_eq "inner working" working "$(optin "$IP" state)"
poll_nonempty "outer pane title becomes AGX1" sh -c "tmux -L $SOCK display -p -t $OUTER '#{pane_title}' | grep '^AGX1|h=$RHOST|'"
poll_eq "outer decoded r_worst" working t show -pqv -t "$OUTER" @agentmux_r_worst
assert_eq "outer r_host" "$RHOST" "$(opt "$OUTER" r_host)"
assert_eq "outer r_kind" claude "$(opt "$OUTER" r_kind)"
assert_eq "outer r_proj" src "$(opt "$OUTER" r_proj)"
assert_nonempty "outer r_exp" "$(opt "$OUTER" r_exp)"
assert_contains "outer badge shows remote working" "●" "$(t display -p -t "$OUTER" '#{E:@agentmux_badge}')"
assert_contains "outer label shows remote host" "$GLY_REMOTE $RHOST/#[fg=cyan]src" "$(t display -p -t "$OUTER" '#{E:@agentmux_label}')"
RE=$(t display -p '#{E:@agentmux_title_enc}')
assert_contains "outer re-embeds inner entry with x=0" "|w=main:1.1|" "$RE"
assert_not_contains "re-embedded entry not marked visible" "|x=1|w=main:1.1|" "$RE"
assert_not_contains "re-embedded title has no nested header" "~AGX1|" "$RE"
SBO=$(python3 "$ROOT/bin/agentmux-sidebar" --once -L "$SOCK" --no-color --width 46 --height 20)
assert_contains "sidebar --once lists remote host" " $RHOST" "$SBO"
assert_contains "sidebar --once lists remote target" "main:1.1" "$SBO"
assert_contains "sidebar --once shows the prompt" "fix the flaky test" "$SBO"

# blocked remotely -> red on the outer within a heartbeat
fire claude PermissionRequest "$ISP" "$IPID" "$IP"
poll_eq "outer r_worst blocked" blocked t show -pqv -t "$OUTER" @agentmux_r_worst
assert_contains "outer badge blocked" "$GLY_BLOCKED" "$(t display -p -t "$OUTER" '#{E:@agentmux_badge}')"

# seen -> idle on the attached inner server
IP2=$(tin new-window -d -P -F '#{pane_id}' -t main: 'sleep 1000')
fire claude SessionStart "$ISP" "$IPID" "$IP2"
fire claude UserPromptSubmit "$ISP" "$IPID" "$IP2"
fire claude Stop "$ISP" "$IPID" "$IP2"
assert_eq "hidden window Stop -> done" done "$(optin "$IP2" state)"
fire claude PostToolUse-match "$ISP" "$IPID" "$IP" PostToolUse
fire claude Stop "$ISP" "$IPID" "$IP"
assert_eq "viewed window Stop -> idle directly" idle "$(optin "$IP" state)"
tin select-window -t main:2
poll_eq "viewing the done window flips it idle" idle tin show -pqv -t "$IP2" @agentmux_state
tin select-window -t main:1

# An expired cache is invalid everywhere, not merely downgraded to an idle badge.
# Stop accepting fresh heartbeats first so the synthetic expiry cannot race title-changed.
t set-hook -gu 'pane-title-changed[70]'
sleep 0.2
t set -pu -t "$OUTER" @agentmux_r_seen \; set -p -t "$OUTER" @agentmux_r_exp 1
assert_empty "expired remote has no effective state" "$(t display -p -t "$OUTER" '#{E:@agentmux_pstate}')"
assert_empty "expired remote has no effective host" "$(t display -p -t "$OUTER" '#{E:@agentmux_phost}')"
assert_not_contains "expired remote label omits host" "$RHOST/" "$(t display -p -t "$OUTER" '#{E:@agentmux_label}')"
assert_empty "expired remote has no timer" "$(t display -p -t "$OUTER" '#{E:@agentmux_timer}')"
EXPIRED_TITLE=$(t display -p '#{E:@agentmux_title_enc}')
assert_not_contains "expired remote is not re-embedded" '|w=main:1.1|' "$EXPIRED_TITLE"

# A local writer taking over a formerly remote pane clears the entire decoded cache in the
# same transaction; the unchanged AGX1 title must not win over the new local state.
FORMER=$(t new-window -d -P -F '#{pane_id}' -t lap: 'sleep 1000')
OLD_TITLE='AGX1|h=oldhost|t=1|hb=0~h=oldhost|s=blocked|k=claude|p=oldproj|b=1|n=0|u=1|x=0|w=old:1.1|d=old~'
t select-pane -T "$OLD_TITLE" -t "$FORMER" \; \
  set -p -t "$FORMER" @agentmux_r_host oldhost \; \
  set -p -t "$FORMER" @agentmux_r_n 1 \; \
  set -p -t "$FORMER" @agentmux_r_worst blocked \; \
  set -p -t "$FORMER" @agentmux_r_worst2 blocked \; \
  set -p -t "$FORMER" @agentmux_r_deleg 0 \; \
  set -p -t "$FORMER" @agentmux_r_proj oldproj \; \
  set -p -t "$FORMER" @agentmux_r_kind claude \; \
  set -p -t "$FORMER" @agentmux_r_start 1 \; \
  set -p -t "$FORMER" @agentmux_r_exp 0 \; \
  set -p -t "$FORMER" @agentmux_r_seen 1 \; \
  set -p -t "$FORMER" @agentmux_r_done oldhost:old:1.1 \; \
  set -p -t "$FORMER" @agentmux_r_prev "$OLD_TITLE" \; \
  set -p -t "$FORMER" @agentmux_r_notified old
fire claude SessionStart "$SP" "$PID" "$FORMER"
fire claude UserPromptSubmit "$SP" "$PID" "$FORMER"
remote_left=""
for name in r_host r_n r_worst r_worst2 r_deleg r_proj r_kind r_start r_exp r_seen r_done r_prev r_notified; do
  value=$(opt "$FORMER" "$name")
  [ -z "$value" ] || remote_left="$remote_left $name=$value"
done
assert_empty "local write clears every remote cache option" "$remote_left"
assert_eq "formerly remote pane shows local state" working "$(t display -p -t "$FORMER" '#{E:@agentmux_pstate}')"
assert_eq "formerly remote pane shows local project" src "$(t display -p -t "$FORMER" '#{E:@agentmux_pproj}')"
FORMER_LABEL=$(t display -p -t "$FORMER" '#{E:@agentmux_label}')
assert_contains "formerly remote label shows local project" src "$FORMER_LABEL"
assert_not_contains "formerly remote label omits old host" oldhost "$FORMER_LABEL"
t kill-window -t "$FORMER"

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
assert_not_contains "hop: no AGX1 title on the outer pane" "AGX1" "$(t display -p -t "$OMP" '#{pane_title}')"
[ -s "$XDG_RUNTIME_DIR/agentmux-${USER:-u}/$OPID/${OIP#%}/outer" ] && ok || ko "hop cache written"
fire claude Stop "$OM_SOCK" "$OPID" "$OIP"
assert_eq "hop: Stop -> done on the outer pane" done "$(opt "$OMP" state)"
fire claude SessionEnd "$OM_SOCK" "$OPID" "$OIP"
assert_empty "hop: SessionEnd clears the outer pane" "$(opt "$OMP" state)"

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

# lonely: kill the only other pane in the sidebar's window (window 2 = $IP2 + sidebar)
tin kill-pane -t "$IP2"
poll_nonempty "lonely sidebar is replaced by a new one" sh -c "tmux -L $SOCK_IN display -p '#{E:@agentmux_sb_pane}' | grep -v '^$SB\$'"
SB2=$got
assert_eq "new sidebar in the current window" "$(tin display -p '#{window_id}')" "$(tin display -p -t "$SB2" '#{window_id}')"
poll_eq "new sidebar marked" 1 tin show -pqv -t "$SB2" @agentmux_sidebar
assert_eq "exactly one sidebar" 1 "$(tin list-panes -a -F '#{@agentmux_sidebar}' | grep -c 1)"

tin run-shell "$ROOT/bin/agentmux toggle '$CLIENT'"
poll_empty "toggle removes the sidebar" tin display -p '#{E:@agentmux_sb_pane}'
assert_eq "sidebar off" 0 "$(tin show -gqv @agentmux_on)"
LOGF=$XDG_STATE_HOME/agentmux/sidebar.log
if [ -s "$LOGF" ]; then ko "sidebar.log not empty: $(head -3 "$LOGF")"; else ok; fi

# ------------------------------------------------------------------ summary ----
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
