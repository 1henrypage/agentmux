#!/bin/sh
# Shared constants for agentmux. Sourced by agentmux.tmux and bin/agentmux.
# hooks/agentmux-hook duplicates these on purpose (it sources nothing on its hot path);
# tests/test_hook_parse.sh asserts the two copies agree.
# shellcheck disable=SC2034
AGENTMUX_PLUGIN=agentmux
AGENTMUX_OPT=@agentmux_
AGENTMUX_SIDEBAR_TITLE=agentmux-sidebar
AGENTMUX_REDRAW_CHANNEL=agentmux-redraw
AGENTMUX_SAN_MAX=24
