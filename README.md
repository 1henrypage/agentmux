# agentmux

Agent overview and state tracking for tmux. Every Claude Code and Codex session you run,
local, inside omnigent, or over ssh, shows up as a badge on its window tab and as a row in a
sidebar, with `working`, `delegating` (sub-agents still running), `blocked` (needs you),
`done` and `idle` states, an elapsed timer, and desktop notifications when an agent you are
not looking at needs input or finishes.

No polling. Agents report through their own hook systems into tmux pane options; tmux
formats render them with zero forks; ssh hops are bridged through the terminal title.

## Install

```tmux
# ~/.tmux.conf
set -g @plugin '1henrypage/agentmux'
set -g @agentmux_width 46          # sidebar columns (default 46)
set -g @agentmux_key a             # prefix + a toggles the sidebar (`off` to skip)
set -g window-status-format "#{E:@agentmux_badge} #I #{E:@agentmux_label}#{E:@agentmux_timer}"
set -g window-status-current-format "#[bold]#{E:@agentmux_badge} #I #{E:@agentmux_label}#{E:@agentmux_timer}#[nobold]"
run '~/.tmux/plugins/tpm/tpm'
```

Then `prefix I` to fetch the plugin and register the hooks once:

```sh
~/.local/share/tmux/plugins/agentmux/bin/agentmux install-hooks
```

This merges tagged entries into `~/.claude/settings.json` and `~/.codex/hooks.json`
(`$CLAUDE_CONFIG_DIR` / `$CODEX_HOME` respected), turns on `[features] hooks = true` in
Codex's `config.toml`, and leaves everything else in those files untouched. It is
idempotent. Restart running agents afterwards (hooks are read at session start); Codex needs
one `/hooks` in its TUI to trust the new entries. `uninstall-hooks` removes exactly what
`install-hooks` added; `status` shows what is registered and what tmux currently sees.

Requirements: tmux >= 3.4, POSIX sh, python3 >= 3.9 (sidebar and title decoding), jq or
python3 for the installer, a Nerd Font for the glyphs.

## What you get

- **Tab badge** per window: `·` idle, `●` working, `󰀐N` delegating with the sub-agent
  count, `󰸇` blocked, `󰄬` done. Worst state wins across panes. Label `project:agent` and a
  ticking `3m05s` timer while a turn runs. Remote agents read `󰐠 host/project:agent`.
- **Sidebar** (`prefix a`): a 46-column pane on the left that follows your current window,
  cannot take focus, and lists every agent on the server grouped by host, worst first, with a
  detail line (the prompt, the tool it is waiting on, `finished 3m ago`).
- **Remote**: a tmux running agentmux on a box you ssh into packs its agents into the
  terminal title; your laptop decodes it. Works through nested hops (bastion, `dbexec`) and
  without a remote tmux (the hook writes the title itself over ssh).
- **omnigent**: agents launched inside omnigent's private tmux are attributed to the outer
  pane that displays them.
- **Notifications**: macOS (`terminal-notifier` or `osascript`) and Linux (`notify-send`),
  only for windows you are not looking at, never with sound.

## Options

| option | default | meaning |
|---|---|---|
| `@agentmux_width` | 46 | sidebar width |
| `@agentmux_key` | `a` | toggle key under prefix, `off` disables |
| `@agentmux_titles` | `auto` | `auto` emits AGX1 to tmux clients and a human title otherwise, `human` never encodes, `off` leaves `set-titles` alone |
| `@agentmux_notify` / `@agentmux_notify_done` | `on` | notifications on blocked / done |
| `@agentmux_ttl` | 14400 | seconds after which a stale state renders idle |
| `@agentmux_sidebar_density` | `full` | `compact` = one line per agent |
| `@agentmux_hostname` | `#{host_short}` | host name override |
| `@agentmux_color_*` | terminal colours | `blocked done delegating working idle project agent remote text fg dim sidebar_bg` |

tmux-resurrect users: add `set -g @resurrect-processes '~agentmux-sidebar'` so the sidebar
survives a restore.

## How it works

See [docs/CONTRACT.md](docs/CONTRACT.md) for the option contract, the AGX1 title grammar,
the hook state machine and the display-pane resolution (direct / omnigent hop / bare ssh).

Known warts: after the focus bounce off the sidebar, `prefix ;` is a no-op once; `prefix o`
from the last pane does not wrap onto the sidebar (by design, it is not focusable). One
sidebar per server, in the current window of the most recently active client.

## Development

```sh
make check     # shellcheck + ruff + unit tests + installer tests + e2e on scratch tmux servers
make e2e       # only the tmux end-to-end suite
```

All tests are hermetic (private sockets, temp `HOME`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`).
