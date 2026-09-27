# agentmux

A tmux plugin that shows what every Claude Code and Codex agent is doing, on the window tab
and in a sidebar.

<!-- TODO(henry): screenshot of the sidebar next to a status line with agents in a few
different states, saved as docs/sidebar.png, then:
![agentmux sidebar](docs/sidebar.png)
-->

I kept losing track of which agent was waiting on me. With several running across tmux
windows, the one you are not looking at is always the one stuck on a permission prompt. The
overview that fixes this comes from [herdr](https://github.com/herdrdev/herdr). herdr is a
multiplexer of its own though, and I wanted to stay in tmux, so agentmux does the same thing
as a plugin: a badge on every tab, a sidebar listing every agent, and a desktop notification
when an agent you are not watching needs you or finishes.

## States

An agent is always in one of five states. When a window holds more than one agent, the tab
shows the worst of them, in this order.

| state | badge | meaning |
|---|---|---|
| `blocked` | `󰸇` | waiting on you: a permission prompt, a question, a plan review |
| `done` | `󰄬` | the turn finished while you were looking elsewhere; clears once you view the window |
| `delegating` | `󰀐N` | the main turn ended but N sub-agents are still running |
| `working` | `●` | a turn is in progress |
| `idle` | `·` | nothing running |

## Install

With TPM, the tmux plugin manager:

```tmux
# ~/.tmux.conf
set -g @plugin '1henrypage/agentmux'
set -g window-status-format "#{E:@agentmux_badge} #I #{E:@agentmux_label}#{E:@agentmux_timer}"
set -g window-status-current-format "#[bold]#{E:@agentmux_badge} #I #{E:@agentmux_label}#{E:@agentmux_timer}#[nobold]"
run '~/.tmux/plugins/tpm/tpm'
```

The two `window-status` lines are what put the badge, label and timer on the tab. If you
already have your own format, drop the three `#{E:@agentmux_*}` fragments into it wherever
you like.

Press `prefix I` to fetch the plugin, then run the installer once from wherever TPM put it
(`~/.tmux/plugins` or `~/.local/share/tmux/plugins`):

```sh
~/.tmux/plugins/agentmux/bin/agentmux install-hooks
```

The installer merges its entries into `~/.claude/settings.json` and `~/.codex/hooks.json`,
sets `hooks = true` under `[features]` in Codex's `config.toml`, and leaves everything else
in those files as it found it. It respects `CLAUDE_CONFIG_DIR` and `CODEX_HOME`, backs each
file up once as `<file>.agentmux.bak`, and running it a second time changes nothing.
`uninstall-hooks` removes exactly the entries it added. `status` prints what is registered
and what tmux currently sees.

Agents read their hooks at startup, so restart any that were already running. Codex also
needs one `/hooks` in its TUI to trust the new entries.

You need tmux 3.4 or newer, a POSIX sh, Python 3.9 or newer for the sidebar, and a Nerd Font
for the glyphs. The installer uses jq when it is present and Python otherwise.

## Usage

### Tabs

Each tab shows the badge, the label `project:agent` and, while a turn runs, a timer such as
`3m05s`. The project is the name of the nearest git checkout above the agent's working
directory, the agent is `claude` or `codex`. With several agent panes in one window the
badge is the worst state among them and the label follows the active pane.

### Sidebar

`prefix a` opens a pane down the left of the current window, 46 columns wide, and closes it
again. It follows you from window to window, lists every agent on the tmux server with the
worst state first, and cannot take focus. Each agent gets a detail line: the prompt it is
working on, the tool it is waiting for permission on, or `finished 3m ago`.
`@agentmux_sidebar_density compact` drops the detail line and fits twice as many agents.

`@agentmux_sidebar_skip` keeps the sidebar out of chosen windows. It is a format evaluated
for the active pane of your current window, and while it is true the sidebar leaves that
window and comes back once you move on. To keep it clear of a pane running another tmux that
marks its title, for example:

```tmux
set -g @agentmux_sidebar_skip '#{m:tmux@*,#{pane_title}}'
```

### Notifications

An agent in a window you are not looking at sends a desktop notification when it becomes
`blocked` or `done`, through `terminal-notifier` or `osascript` on macOS and `notify-send`
on Linux. Windows you are looking at never notify, and nothing ever makes a sound.

### Remote hosts

Each tmux server shows its own agents. Install agentmux in the tmux on a host you ssh into
and its agents appear in that tmux's tabs and sidebar.

### omnigent

Agents started inside omnigent's private tmux server show up on the outer pane that
displays them.

## Options

Set these in `~/.tmux.conf` before the `run` line for TPM.

| option | default | meaning |
|---|---|---|
| `@agentmux_width` | `46` | sidebar width in columns |
| `@agentmux_key` | `a` | toggle key under prefix, `off` for none |
| `@agentmux_titles` | `on` | `on` sets the terminal title to `session:window`, plus ` - agent blocked` or ` - agent done` while an agent is in that state; `off` leaves `set-titles` alone, and your own `set-titles-string` can embed `#{E:@agentmux_title_human}` |
| `@agentmux_notify` | `on` | notify on `blocked` |
| `@agentmux_notify_done` | `on` | notify on `done` |
| `@agentmux_ttl` | `14400` | seconds after which a stale state renders as `idle` |
| `@agentmux_sidebar_density` | `full` | `compact` for one line per agent |
| `@agentmux_sidebar_skip` | unset | format; while it is true for the active pane of your current window, the sidebar stays out of that window |
| `@agentmux_color_<name>` | terminal colours | `blocked`, `done`, `delegating`, `working`, `idle`, `project`, `agent`, `text`, `fg`, `dim`, `sidebar_bg` |

If you use tmux-resurrect, add `set -g @resurrect-processes '~agentmux-sidebar'` so the
sidebar comes back after a restore.

## How it works

Claude Code and Codex both have hook systems, and the installer registers one small POSIX
sh script as the hook for the events that matter: session start and end, prompt submitted,
permission request, tool use, stop, sub-agent start and stop. On each event the hook works
out the new state and writes it into options on the tmux pane the agent runs in. The
badge, label and timer are tmux formats over those options, so drawing the status line
never forks a process, and nothing polls. The sidebar is a Python renderer that repaints
when the hook signals it.

The option contract and the hook state machine are in
[docs/CONTRACT.md](docs/CONTRACT.md).

## Known warts

- After the focus bounce off the sidebar, `prefix ;` is a no-op once.
- `prefix o` from the last pane does not wrap onto the sidebar. That is by design, the
  sidebar is not focusable.
- One sidebar per tmux server, in the current window of the client that was active most
  recently.

## Development

```sh
make check   # shellcheck, ruff, unit tests, installer tests, end-to-end on scratch tmux servers
make e2e     # the tmux end-to-end suite alone
```

Every test is hermetic: a private tmux socket and a temporary `HOME`, `CLAUDE_CONFIG_DIR`
and `CODEX_HOME`, so nothing touches your real config.

## Licence

MIT, see [LICENSE](LICENSE).
