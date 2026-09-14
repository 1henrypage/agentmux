#!/bin/sh
# agentmux - TPM entry point. Sets option defaults, the format fragments the status line
# reads (`#{E:@agentmux_badge}` / `_label` / `_timer`), the sidebar management hooks, the
# outgoing AGX1 title channel and the toggle key. Everything here is fork-free at runtime:
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
default "${O}titles" auto
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
default "${O}color_remote" blue
default "${O}color_text" white
default "${O}color_fg" default
default "${O}color_dim" colour240
default "${O}color_sidebar_bg" default
[ -n "$(opt "${O}on")" ] || setg "${O}on" 0
[ -n "$(opt "${O}owner")" ] || setg "${O}owner" "$(tmux display -p '#{client_name}' 2>/dev/null || true)"

WIDTH=$(opt "${O}width")
KEY=$(opt "${O}key")

# ------------------------------------------------------------------------ host ----
# host_short unless the user overrides it (containers, "localhost", tests).
HOSTF="#{?#{${O}hostname},#{${O}hostname},#{host_short}}"

# ------------------------------------------------------------------------ glyphs ----
G_WORKING='●'   # U+25CF
G_IDLE='·'      # U+00B7
G_BLOCKED='󰸇'   # U+F0E07 nf-md-hand_back_right
G_DONE='󰄬'      # U+F012C nf-md-check
G_DELEG='󰀐'     # U+F0010 nf-md-account-multiple
G_REMOTE='󰐠'    # U+F0420 nf-md-remote

# ------------------------------------------------------------- per-pane state ----
# Shell gate: a pane's agent state counts only while its foreground process is not a shell.
# This self-heals a kill -9'd agent whose SessionEnd never fired.
SG='#{m/r:^-?(zsh|bash|fish|sh|dash|ksh|nu)$,#{pane_current_command}}'
# Local state, rendered idle once older than @agentmux_ttl.
LS="#{?#{m:-*,#{e|-|:#{e|+|:#{${O}updated},#{${O}ttl}},%s}},idle,#{${O}state}}"
# Remote (ssh pane) state, from title-changed's summary while its expiry is in the future.
RS="#{?#{&&:#{${O}r_exp},#{m:-*,#{e|-|:#{${O}r_exp},%s}}},idle,#{?#{${O}r_seen},#{${O}r_worst2},#{${O}r_worst}}}"
setg "${O}pstate" "#{?${SG},,#{?#{${O}r_host},${RS},#{?#{${O}state},${LS},}}}"
# 1 when the pane is a live agent (local or remote), 0 otherwise.
LIVE="#{&&:#{!:${SG}},#{?#{${O}r_host},1,#{?#{${O}state},1,0}}}"
setg "${O}plive" "$LIVE"
setg "${O}pproj" "#{?#{${O}r_host},#{${O}r_proj},#{${O}project}}"
setg "${O}pkind" "#{?#{${O}r_host},#{${O}r_kind},#{${O}kind}}"
setg "${O}pstart" "#{?#{${O}r_host},#{${O}r_start},#{${O}start}}"
setg "${O}phost" "#{${O}r_host}"
setg "${O}pdeleg" "#{?#{${O}r_host},#{${O}r_deleg},#{${O}subagents}}"

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
wpick host

# ------------------------------------------------------------- tab fragments ----
WS="#{E:${O}wstates}"
setg "${O}badge" "#{?#{m:*blocked*,${WS}},#[fg=#{${O}color_blocked}]${G_BLOCKED},#{?#{m:*done*,${WS}},#[fg=#{${O}color_done}]${G_DONE},#{?#{m:*delegating*,${WS}},#[fg=#{${O}color_delegating}]${G_DELEG}#{E:${O}wdeleg},#{?#{m:*working*,${WS}},#[fg=#{${O}color_working}]${G_WORKING},#[fg=#{${O}color_idle}]${G_IDLE}}}}}#[fg=#{${O}color_fg}]"

setg "${O}label" "#{?automatic-rename,#{?#{m:?*,#{E:${O}whost}},#[fg=#{${O}color_remote}]${G_REMOTE} #{E:${O}whost}/,}#[fg=#{${O}color_project}]#{?#{m:?*,#{E:${O}wproj}},#{E:${O}wproj},#{b:pane_current_path}}#[fg=#{${O}color_dim}]:#[fg=#{${O}color_agent}]#{?#{m:?*,#{E:${O}wkind}},#{E:${O}wkind},#{pane_current_command}}#[fg=#{${O}color_fg}],#[fg=#{${O}color_fg}]#W}"

SECS="#{E:${O}wsecs}"
setg "${O}wsecs" "#{e|-|:%s,#{E:${O}wstart}}"
MIN="#{e|/|:${SECS},60}"
# "3m05s" under an hour, "1h02m" above (seconds/minutes zero-padded to two digits).
setg "${O}elapsed" "#{?#{m:-*,#{e|-|:${SECS},3600}},${MIN}m#{?#{m:-*,#{e|-|:#{e|m|:${SECS},60},10}},0,}#{e|m|:${SECS},60}s,#{e|/|:${SECS},3600}h#{?#{m:-*,#{e|-|:#{e|m|:${MIN},60},10}},0,}#{e|m|:${MIN},60}m}"
setg "${O}timer" "#{?#{m:?*,#{E:${O}wstart}}, #[fg=#{${O}color_text}]#{E:${O}elapsed}#[fg=#{${O}color_fg}],}"

# ------------------------------------------------------------- title channel ----
# Outgoing AGX1 title: every live agent pane on this server, plus anything decoded from our
# own ssh panes re-embedded verbatim (their x=1 rewritten to x=0 when that pane is hidden).
SAFE='[^A-Za-z0-9 ._@+()-]'
VIS="#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}"
ENTRY="#{?${SG},,#{?#{${O}state},h=${HOSTF}|s=${LS}|k=#{${O}kind}|p=#{s/${SAFE}/_/:${O}project}|b=#{${O}start}|n=#{${O}subagents}|u=#{${O}updated}|x=${VIS}|w=#{s/[^A-Za-z0-9._-]/_/:session_name}:#{window_index}.#{pane_index}|d=#{s/${SAFE}/_/:#{=32:#{${O}detail}}}~,}#{?#{m:${AGENTMUX_MAGIC}|*,#{pane_title}},#{?${VIS},#{s/^${AGENTMUX_MAGIC}[|][^~]*~//:pane_title},#{s/[|]x=1[|]/|x=0|/:#{s/^${AGENTMUX_MAGIC}[|][^~]*~//:pane_title}}},}}"
setg "${O}title_enc" "${AGENTMUX_MAGIC}|h=${HOSTF}|t=#{e|/|:%s,60}|hb=60~#{S:#{W:#{P:${ENTRY}}}}"
setg "${O}allstates" "#{S:#{W:#{E:${O}wstates}}}"
setg "${O}title_human" "#{session_name}:#{window_name}#{?#{m:*blocked*,#{E:${O}allstates}}, - agent blocked,#{?#{m:*done*,#{E:${O}allstates}}, - agent done,}}"
case $(opt "${O}titles") in
auto)
  tmux set -as terminal-features ",tmux*:title"
  setg set-titles on
  setg set-titles-string "#{?#{m/r:^(tmux|screen),#{client_termname}},#{=1800:#{E:${O}title_enc}},#{E:${O}title_human}}"
  ;;
human)
  setg set-titles on
  setg set-titles-string "#{E:${O}title_human}"
  ;;
esac

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
# The owner client's current window / zoom flag / whether it is wide enough for a sidebar.
TGT_PRE="#{L:#{?#{==:#{client_name},#{${O}owner}},"
TGT_POST=",}}"
setg "${O}tgt_win" "${TGT_PRE}#{window_id}${TGT_POST}"
setg "${O}tgt_zoom" "${TGT_PRE}#{window_zoomed_flag}${TGT_POST}"
setg "${O}tgt_wide" "${TGT_PRE}#{?#{m:-*,#{e|-|:#{e|-|:#{window_width},#{${O}width}},30}},0,1}${TGT_POST}"

SB="#{E:${O}sb_pane}"
TW="#{E:${O}tgt_win}"
ENSURE="run-shell -b '$PLUGIN_DIR/bin/agentmux ensure'"
JOIN="join-pane -bdfh -l #{${O}width} -s ${SB} -t ${TW}"
FOLLOW_COND="#{&&:#{${O}on},#{&&:#{m:?*,${SB}},#{&&:#{m:?*,${TW}},#{&&:#{!=:#{E:${O}sb_win},${TW}},#{&&:#{!:#{E:${O}tgt_zoom}},#{E:${O}tgt_wide}}}}}}"
LONELY_COND="#{&&:#{m:?*,${SB}},#{==:#{E:${O}sb_npanes},1}}"
FIX_COND="#{&&:#{m:?*,${SB}},#{&&:#{!:#{E:${O}tgt_zoom}},#{&&:#{E:${O}tgt_wide},#{==:#{E:${O}sb_win},${TW}}}}}"
FIX="#{?#{E:${O}sb_ok},#{?#{E:${O}sb_wok},,resize-pane -x #{${O}width} -t ${SB}},break-pane -d -s ${SB} ; ${JOIN}}"
setg "${O}follow" "#{?${FOLLOW_COND},${JOIN},}"
# Exclusive branches so a generated command list never references a pane it just killed.
setg "${O}layout" "#{?${FOLLOW_COND},${JOIN},#{?${LONELY_COND},kill-pane -t ${SB} ; ${ENSURE},#{?${FIX_COND},${FIX},}}}"
setg "${O}ensure_or_layout" "#{?#{&&:#{${O}on},#{!:#{m:?*,${SB}}}},${ENSURE},#{E:${O}layout}}"
# Seen: a done pane you are looking at becomes idle; a viewed ssh pane marks its remote
# done-set as seen. Always ends with the redraw signal so the sidebar repaints.
setg "${O}seen" "#{P:#{?#{&&:#{==:#{${O}state},done},#{&&:#{window_active},#{session_attached}}},set -p -t #{pane_id} ${O}state idle ; ,}#{?#{&&:#{${O}r_host},#{&&:#{!:#{${O}r_seen}},#{&&:#{window_active},#{session_attached}}}},set -p -t #{pane_id} ${O}r_seen 1 ; ,}}wait-for -S ${AGENTMUX_REDRAW_CHANNEL}"

# ------------------------------------------------------------- hooks (indices 70-79) ----
hook() { tmux set-hook -g "$1" "$2"; }
hook 'session-window-changed[70]' "run-shell -C '#{E:${O}layout}'"
hook 'session-window-changed[71]' "run-shell -C '#{E:${O}seen}'"
hook 'client-session-changed[70]' "run-shell -C '#{E:${O}layout}'"
hook 'client-session-changed[71]' "run-shell -C '#{E:${O}seen}'"
hook 'client-active[70]' "set -gF ${O}owner '#{client_name}'"
hook 'client-active[71]' "run-shell -C '#{E:${O}ensure_or_layout}'"
hook 'client-attached[70]' "set -gF ${O}owner '#{client_name}'"
hook 'client-attached[71]' "run-shell -C '#{E:${O}ensure_or_layout}'"
hook 'client-focus-in[70]' "run-shell -C '#{E:${O}seen}'"
# Focus bounce: the sidebar can never be the active pane.
hook 'window-pane-changed[70]' "if -F '#{${O}sidebar}' 'select-pane -l'"
hook 'window-pane-changed[71]' "run-shell -C '#{E:${O}seen}'"
hook 'window-layout-changed[70]' "run-shell -C '#{E:${O}layout}'"
hook 'after-select-layout[70]' "run-shell -C '#{E:${O}layout}'"
hook 'after-kill-pane[70]' "run-shell -C '#{E:${O}layout}'"
hook 'pane-exited[70]' "run-shell -C '#{E:${O}layout}'"
hook 'pane-title-changed[70]' "if -F '#{m:${AGENTMUX_MAGIC}|*,#{pane_title}}' \"run-shell -b '$PLUGIN_DIR/bin/agentmux title-changed #{pane_id}'\""

# ------------------------------------------------------------- key ----
if [ -n "$KEY" ] && [ "$KEY" != off ]; then
  tmux bind-key -N 'agentmux: toggle the agent sidebar' "$KEY" run-shell "$PLUGIN_DIR/bin/agentmux toggle '#{client_name}'"
fi

# A sidebar that survived a server restart (tmux-resurrect) or a reload re-marks itself;
# nothing to do here. Make sure the renderer can find python3 later.
: "$WIDTH"
