#!/bin/sh
# agentmux - TPM entry point. Sets option defaults, the format fragments the status line
# reads (`#{E:@agentmux_badge}` / `_label` / `_timer`), the terminal title, the sidebar
# management hooks and the toggle key. Everything here is fork-free at runtime:
# hooks run `run-shell -C '<format>'`, which expands a format into a tmux command list and
# executes it in-server (an empty expansion is a no-op).
#
# Every glyph below is a Nerd Font codepoint verified against FantasqueSansM Nerd Font Mono.
# See docs/CONTRACT.md for the option contract.
set -u
PLUGIN_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/constants.sh
. "$PLUGIN_DIR/lib/constants.sh"

O=$AGENTMUX_OPT

opt() { tmux show -gqv "$1" 2>/dev/null; }
default() { [ -n "$(opt "$1")" ] || tmux set -g "$1" "$2"; }
setg() { tmux set -g "$1" "$2"; }

# --------------------------------------------------------------------------- defaults ----
default "${O}width" 46
default "${O}key" a
default "${O}titles" on
default "${O}notify" on
default "${O}notify_done" on
default "${O}ttl" 14400
default "${O}sidebar_density" full
default "${O}color_blocked" red
default "${O}color_done" green
default "${O}color_delegating" magenta
default "${O}color_working" yellow
default "${O}color_idle" colour240
default "${O}color_project" cyan
default "${O}color_agent" colour245
default "${O}color_text" white
default "${O}color_fg" default
default "${O}color_dim" colour240
default "${O}color_sidebar_bg" default
[ -n "$(opt "${O}on")" ] || setg "${O}on" 0
[ -n "$(opt "${O}owner")" ] || setg "${O}owner" "$(tmux display -p '#{client_name}' 2>/dev/null || true)"

WIDTH=$(opt "${O}width")
KEY=$(opt "${O}key")

# ------------------------------------------------------------------------ glyphs ----
G_WORKING='●'   # U+25CF
G_IDLE='·'      # U+00B7
G_BLOCKED='󰸇'   # U+F0E07 nf-md-hand_back_right
G_DONE='󰄬'      # U+F012C nf-md-check
G_DELEG='󰀐'     # U+F0010 nf-md-account-multiple

# ------------------------------------------------------------- per-pane state ----
# Shell gate: a pane's agent state counts only while its foreground process is not a shell.
# This self-heals a kill -9'd agent whose SessionEnd never fired.
SG='#{m/r:^-?(zsh|bash|fish|sh|dash|ksh|nu)$,#{pane_current_command}}'
# State, rendered idle once older than @agentmux_ttl.
LS="#{?#{m:-*,#{e|-|:#{e|+|:#{${O}updated},#{${O}ttl}},%s}},idle,#{${O}state}}"
setg "${O}pstate" "#{?${SG},,#{?#{${O}state},${LS},}}"
# 1 when the pane is a live agent, 0 otherwise.
setg "${O}plive" "#{&&:#{!:${SG}},#{?#{${O}state},1,0}}"
setg "${O}pproj" "#{${O}project}"
setg "${O}pkind" "#{${O}kind}"
setg "${O}pstart" "#{${O}start}"
setg "${O}pdeleg" "#{${O}subagents}"

# ------------------------------------------------------------- per-window ----
setg "${O}wstates" "#{P:#{E:${O}pstate} }"
setg "${O}wdeleg" "#{s/~.*\$//:#{P:#{?#{==:#{E:${O}pstate},delegating},#{E:${O}pdeleg}~,}}}"
# wpick X: the active pane's X if it is a live agent with a value, else the first live pane's.
wpick() {
  act="#{P:#{?#{&&:#{pane_active},#{E:${O}plive}},#{E:${O}p$1},}}"
  first="#{s/~.*\$//:#{P:#{?#{&&:#{E:${O}plive},#{m:?*,#{E:${O}p$1}}},#{E:${O}p$1}~,}}}"
  setg "${O}w$1" "#{?#{m:?*,${act}},${act},${first}}"
}
wpick proj
wpick kind
wpick start

# ------------------------------------------------------------- tab fragments ----
WS="#{E:${O}wstates}"
setg "${O}badge" "#{?#{m:*blocked*,${WS}},#[fg=#{${O}color_blocked}]${G_BLOCKED},#{?#{m:*done*,${WS}},#[fg=#{${O}color_done}]${G_DONE},#{?#{m:*delegating*,${WS}},#[fg=#{${O}color_delegating}]${G_DELEG}#{E:${O}wdeleg},#{?#{m:*working*,${WS}},#[fg=#{${O}color_working}]${G_WORKING},#[fg=#{${O}color_idle}]${G_IDLE}}}}}#[fg=#{${O}color_fg}]"

setg "${O}label" "#{?automatic-rename,#[fg=#{${O}color_project}]#{?#{m:?*,#{E:${O}wproj}},#{E:${O}wproj},#{b:pane_current_path}}#[fg=#{${O}color_dim}]:#[fg=#{${O}color_agent}]#{?#{m:?*,#{E:${O}wkind}},#{E:${O}wkind},#{pane_current_command}}#[fg=#{${O}color_fg}],#[fg=#{${O}color_fg}]#W}"

SECS="#{E:${O}wsecs}"
setg "${O}wsecs" "#{e|-|:%s,#{E:${O}wstart}}"
MIN="#{e|/|:${SECS},60}"
# "3m05s" under an hour, "1h02m" above (seconds/minutes zero-padded to two digits).
setg "${O}elapsed" "#{?#{m:-*,#{e|-|:${SECS},3600}},${MIN}m#{?#{m:-*,#{e|-|:#{e|m|:${SECS},60},10}},0,}#{e|m|:${SECS},60}s,#{e|/|:${SECS},3600}h#{?#{m:-*,#{e|-|:#{e|m|:${MIN},60},10}},0,}#{e|m|:${MIN},60}m}"
setg "${O}timer" "#{?#{m:?*,#{E:${O}wstart}}, #[fg=#{${O}color_text}]#{E:${O}elapsed}#[fg=#{${O}color_fg}],}"

# ------------------------------------------------------------- terminal title ----
# "session:window", plus " - agent blocked" / " - agent done" while any agent on this server
# is in that state. @agentmux_title_human is public: a config that owns set-titles-string
# itself (@agentmux_titles off) embeds it with #{E:@agentmux_title_human}.
setg "${O}allstates" "#{S:#{W:#{E:${O}wstates}}}"
setg "${O}title_human" "#{session_name}:#{window_name}#{?#{m:*blocked*,#{E:${O}allstates}}, - agent blocked,#{?#{m:*done*,#{E:${O}allstates}}, - agent done,}}"
# Anything but `off` counts as on, so a value left over from before (`auto`, `human`) still works.
if [ "$(opt "${O}titles")" != off ]; then
  setg set-titles on
  setg set-titles-string "#{E:${O}title_human}"
fi

# ------------------------------------------------------------- sidebar finders ----
# No cached pane id anywhere: the sidebar is whichever pane carries @agentmux_sidebar.
# FOOTGUN: never build a format inside "$(...)" here. bash 3.2 (macOS /bin/sh) mis-parses
# nested #{..#{..},..} inside a quoted command substitution and silently brace-expands it.
# Assemble formats from variables instead.
SBQ_PRE="#{S:#{W:#{P:#{?#{${O}sidebar},"
SBQ_POST=",}}}}"
setg "${O}sb_pane" "${SBQ_PRE}#{pane_id}${SBQ_POST}"
setg "${O}sb_win" "${SBQ_PRE}#{window_id}${SBQ_POST}"
setg "${O}sb_npanes" "${SBQ_PRE}#{window_panes}${SBQ_POST}"
setg "${O}sb_ok" "${SBQ_PRE}#{&&:#{==:#{pane_left},0},#{&&:#{==:#{pane_top},0},#{==:#{pane_height},#{window_height}}}}${SBQ_POST}"
setg "${O}sb_wok" "${SBQ_PRE}#{==:#{pane_width},#{${O}width}}${SBQ_POST}"
# The owner client's current window / zoom flag / whether it is wide enough for a sidebar /
# whether @agentmux_sidebar_skip (a user format, evaluated for that window's active pane)
# keeps the sidebar out of it. Each is empty when the owner is not attached.
# FOOTGUN: inside #{L:} the window and pane are still the enclosing context's (a hook's target
# window, say), not the looped client's. So the owner's window is found explicitly: its
# session (client_session) and that session's active window, whose pane is its active pane.
TGT_PRE="#{L:#{?#{==:#{client_name},#{${O}owner}},#{S:#{?#{==:#{session_name},#{client_session}},#{W:#{?window_active,"
TGT_POST=",}},}},}}"
setg "${O}tgt_win" "${TGT_PRE}#{window_id}${TGT_POST}"
setg "${O}tgt_zoom" "${TGT_PRE}#{window_zoomed_flag}${TGT_POST}"
setg "${O}tgt_wide" "${TGT_PRE}#{?#{m:-*,#{e|-|:#{e|-|:#{window_width},#{${O}width}},30}},0,1}${TGT_POST}"
setg "${O}tgt_skip" "${TGT_PRE}#{?#{E:${O}sidebar_skip},1,0}${TGT_POST}"

SB="#{E:${O}sb_pane}"
SBW="#{E:${O}sb_win}"
TW="#{E:${O}tgt_win}"
ENSURE="run-shell -b '$PLUGIN_DIR/bin/agentmux ensure'"
JOIN="join-pane -bdfh -l #{${O}width} -s ${SB} -t ${TW}"
FOLLOW_COND="#{&&:#{${O}on},#{&&:#{m:?*,${SB}},#{&&:#{m:?*,${TW}},#{&&:#{!=:${SBW},${TW}},#{&&:#{!:#{E:${O}tgt_zoom}},#{&&:#{E:${O}tgt_wide},#{!:#{E:${O}tgt_skip}}}}}}}}"
LONELY_COND="#{&&:#{m:?*,${SB}},#{==:#{E:${O}sb_npanes},1}}"
SKIP_COND="#{&&:#{m:?*,${SB}},#{&&:#{==:${SBW},${TW}},#{E:${O}tgt_skip}}}"
FIX_COND="#{&&:#{m:?*,${SB}},#{&&:#{!:#{E:${O}tgt_zoom}},#{&&:#{E:${O}tgt_wide},#{&&:#{==:${SBW},${TW}},#{!:#{E:${O}tgt_skip}}}}}}"
# `run-shell -C` runs the commands it generates on a later event-loop turn, so two hooks for
# one event (e.g. after-kill-pane and window-layout-changed) can both decide to kill the same
# sidebar, and the loser's kill-pane fails in the user's own command. A kill therefore
# re-checks, when it runs, that the pane it names is still the sidebar: the #-escaped format
# below survives this expansion and is evaluated by `if -F`, atomically with the kill.
IF_STILL_SB="if -F \"##{==:##{E:${O}sb_pane#}#,${SB}#}\""

# ------------------------------------------------- window layout history (give-back) ----
# The sidebar borrows columns from every pane of a window it joins and gives each pane back
# exactly what it lent once it leaves (docs/CONTRACT.md, "Window options"). The history:
#   wclean  the window's layout right before the sidebar arrived
#   wsq0    its layout right after (wclean vs wsq0 is what each cell lent)
#   wsq     its layout as of the last change while the sidebar is in it; still set on a
#           window the sidebar has left, it means that window is owed its give-back
# FOOTGUN: tmux fires no hook for anything done inside a hook (notify.c drops notifications
# raised while a hook's commands run, and `run-shell -C` runs what it generates with the
# hook's state), so @agentmux_track never sees the sidebar move when a format below moves
# it. Each such move does its own bookkeeping instead, and gives the window it left back
# synchronously (`run-shell`, no -b): nothing later in the same queue, such as the next
# window switch, can bring the sidebar back before that window is restored.
# Every #{window_layout} below is escaped (##{..#}) so that it expands when its command runs.
setg "${O}sb_at" "${SBQ_PRE}#{pane_id}#{window_id}${SBQ_POST}"
# Like IF_STILL_SB, and also re-checks the window: bookkeeping for the wrong window is worse
# than none.
IF_SB_AT="if -F \"##{==:##{E:${O}sb_at#}#,${SB}${SBW}#}\""
LAYOUT="'##{window_layout#}'"
GIVE_BACK="run-shell '$PLUGIN_DIR/bin/agentmux relayout ${SBW}'"
SQ_SBW="set -wF -t ${SBW} ${O}wsq ${LAYOUT}"
SQ_TW="set -wF -t ${TW} ${O}wsq ${LAYOUT}"
# The follow joins the sidebar in right here, so it shows up with the window switch, and
# gives the window it left back straight after.
FOLLOW="${IF_SB_AT} \"${SQ_SBW} ; set -wF -t ${TW} ${O}wclean ${LAYOUT} ; ${JOIN} ; set -wF -t ${TW} ${O}wsq0 ${LAYOUT} ; ${SQ_TW} ; ${GIVE_BACK}\""
# An eviction happens in the window you are looking at: `agentmux close` kills the sidebar
# and gives the window back in one tmux command, which a format cannot, as the give-back
# has to be computed first.
SKIP="run-shell '$PLUGIN_DIR/bin/agentmux close ${SB} ${SBW}'"
# A fix only re-places the sidebar within its window: the window's history stands, wsq
# moves on.
FIX="#{?#{E:${O}sb_ok},#{?#{E:${O}sb_wok},,${IF_SB_AT} \"resize-pane -x #{${O}width} -t ${SB} ; ${SQ_TW}\"},${IF_SB_AT} \"break-pane -d -s ${SB} ; ${JOIN} ; ${SQ_TW}\"}"
# Exclusive branches so a generated command list never references a pane it just killed.
# A skipped window evicts the sidebar but leaves @agentmux_on alone, so ensure_or_layout
# brings it back as soon as the owner's window is no longer skipped.
setg "${O}layout" "#{?${FOLLOW_COND},${FOLLOW},#{?${LONELY_COND},${IF_STILL_SB} \"kill-pane -t ${SB} ; ${ENSURE}\",#{?${SKIP_COND},${SKIP},#{?${FIX_COND},${FIX},}}}}"
# Forks `ensure` only when it would create a sidebar: on, none yet, and a target it may use.
ENSURE_COND="#{&&:#{${O}on},#{&&:#{!:#{m:?*,${SB}}},#{&&:#{!:#{E:${O}tgt_zoom}},#{&&:#{E:${O}tgt_wide},#{!:#{E:${O}tgt_skip}}}}}}"
setg "${O}ensure_or_layout" "#{?${ENSURE_COND},${ENSURE},#{E:${O}layout}}"

# @agentmux_track, on window-layout-changed, covers the rest: changes made outside any
# hook, i.e. the user's own. In a window holding the sidebar it moves wsq on, re-checking
# when the command runs, as the sidebar may be gone by then and a late wsq would re-arm a
# give-back already done. In a window without it, a set wsq means the sidebar was killed,
# died or was moved by hand: give the window back now. (`toggle` kills the sidebar outside a
# hook too, but takes the history with the kill and gives the window back itself.)
HAS_SB="#{P:#{?#{${O}sidebar},1,}}"
TRACK_SB="if -F -t #{window_id} \"##{P:##{?##{${O}sidebar#}#,1#,#}#}\" \"set -wF -t #{window_id} ${O}wsq ${LAYOUT}\""
TRACK_GONE="run-shell '$PLUGIN_DIR/bin/agentmux relayout #{window_id}'"
setg "${O}track" "#{?${HAS_SB},${TRACK_SB},#{?#{${O}wsq},${TRACK_GONE},}}"

# Seen: a done pane you are looking at becomes idle. Always ends with the redraw signal so
# the sidebar repaints.
setg "${O}seen" "#{P:#{?#{&&:#{==:#{${O}state},done},#{&&:#{window_active},#{session_attached}}},set -p -t #{pane_id} ${O}state idle ; ,}}wait-for -S ${AGENTMUX_REDRAW_CHANNEL}"

# ------------------------------------------------------------- hooks (indices 70-79) ----
# Anything that can change the owner's window, or what its active pane is showing, runs
# ensure_or_layout: that is what re-creates a sidebar evicted by @agentmux_sidebar_skip.
hook() { tmux set-hook -g "$1" "$2"; }
hook 'session-window-changed[70]' "run-shell -C '#{E:${O}ensure_or_layout}'"
hook 'session-window-changed[71]' "run-shell -C '#{E:${O}seen}'"
hook 'client-session-changed[70]' "run-shell -C '#{E:${O}ensure_or_layout}'"
hook 'client-session-changed[71]' "run-shell -C '#{E:${O}seen}'"
hook 'client-active[70]' "set -gF ${O}owner '#{client_name}'"
hook 'client-active[71]' "run-shell -C '#{E:${O}ensure_or_layout}'"
hook 'client-attached[70]' "set -gF ${O}owner '#{client_name}'"
hook 'client-attached[71]' "run-shell -C '#{E:${O}ensure_or_layout}'"
hook 'client-focus-in[70]' "run-shell -C '#{E:${O}seen}'"
# Focus bounce: the sidebar can never be the active pane.
hook 'window-pane-changed[70]' "if -F '#{${O}sidebar}' 'select-pane -l'"
hook 'window-pane-changed[71]' "run-shell -C '#{E:${O}seen}'"
hook 'window-pane-changed[72]' "run-shell -C '#{E:${O}ensure_or_layout}'"
hook 'window-layout-changed[70]' "run-shell -C '#{E:${O}layout}'"
hook 'window-layout-changed[71]' "run-shell -C '#{E:${O}track}'"
# A command hook runs in the queue of the command that fired it, and `run-shell -C` there
# holds up the rest of that queue until the next event-loop turn. Only pay that when there
# is something to do: then a command list that kills a pane and lays its window out again
# (`agentmux close`) runs in one go, and tmux resizes each pane once.
LAYOUT_IF_ANY="if -F '#{m:?*,#{E:${O}layout}}' \"run-shell -C '#{E:${O}layout}'\""
hook 'after-select-layout[70]' "$LAYOUT_IF_ANY"
hook 'after-kill-pane[70]' "$LAYOUT_IF_ANY"
hook 'pane-exited[70]' "run-shell -C '#{E:${O}layout}'"
# Skip formats usually read the pane title. Zero forks unless the sidebar must be re-created.
hook 'pane-title-changed[70]' "run-shell -C '#{E:${O}ensure_or_layout}'"

# A reload (tpm, source-file) must not leave history on a window the sidebar is not in: a
# stale wsq would fire a give-back against whatever that window looks like by then.
CLEAR_STALE="#{S:#{W:#{?${HAS_SB},,set -wu -t #{window_id} ${O}wclean ; set -wu -t #{window_id} ${O}wsq0 ; set -wu -t #{window_id} ${O}wsq ; }}}"
tmux run-shell -C "$CLEAR_STALE"

# ------------------------------------------------------------- key ----
if [ -n "$KEY" ] && [ "$KEY" != off ]; then
  tmux bind-key -N 'agentmux: toggle the agent sidebar' "$KEY" run-shell "$PLUGIN_DIR/bin/agentmux toggle '#{client_name}'"
fi

# A sidebar that survived a server restart (tmux-resurrect) or a reload re-marks itself;
# nothing to do here. Make sure the renderer can find python3 later.
: "$WIDTH"
