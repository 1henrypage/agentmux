# agentmux data contract

Everything agentmux does flows through two channels: **pane options** on the tmux server
that displays an agent, and a **scratch directory** the hook keeps as its source of truth.
This file is the contract between the pieces (`hooks/agentmux-hook`, `agentmux.tmux`,
`bin/agentmux`, `agentmux/sidebar.py`). Change it here first.

A tmux server shows the agents running under it and nothing else. An agent on a host you ssh
into shows up in the tmux on that host.

## States

`idle`, `working`, `delegating` (main turn ended, N sub-agents still live), `blocked`,
`done`. Ladder (worst first): `blocked > done > delegating > working > idle`.

`done` persists until the pane's window is viewed by an attached client, then the tmux side
flips it to `idle` (the hook itself writes `idle` instead of `done` when the pane is already
viewed). Hooks never cache the state option; they derive it from the scratch markers.

## Pane options (written by the hook on the display pane)

| option | values | notes |
|---|---|---|
| `@agentmux_state` | `idle\|working\|delegating\|blocked\|done` | tmux side may flip `done` to `idle` |
| `@agentmux_kind` | `claude\|codex` | written with every state write |
| `@agentmux_project` | `[A-Za-z0-9_.-]`, at most 24 | `${CLAUDE_PROJECT_DIR##*/}`, else nearest `.git` above `cwd`, else `${cwd##*/}` |
| `@agentmux_start` | epoch of the last `UserPromptSubmit` | empty while idle/done |
| `@agentmux_subagents` | integer >= 0 | live sub-agents of the current turn |
| `@agentmux_detail` | `[A-Za-z0-9_. -]`, at most 24 | blocked: `permission <tool>`, `question`, `plan review`, `elicitation`, `agent input`; else the prompt excerpt; `resuming` after an assumed auto-resume |
| `@agentmux_sid` | agent session id | |
| `@agentmux_updated` | epoch of the last write | formats render a state older than `@agentmux_ttl` as idle |
| `@agentmux_sidebar` | `1` on the sidebar pane | set by `ensure` and by the renderer |

`SessionEnd` unsets all of them (`set -pu`).

## Global options

Set by the user before `run tpm`; the plugin fills in defaults.

`@agentmux_width` (46), `@agentmux_key` (`a`, `off` to skip the binding),
`@agentmux_titles` (`on|off`), `@agentmux_notify` (`on|off`),
`@agentmux_notify_done` (`on|off`), `@agentmux_ttl` (14400 s),
`@agentmux_sidebar_density` (`full|compact`), `@agentmux_sidebar_skip` (a format, unset by
default, see [Sidebar placement](#sidebar-placement)), and the eleven colours
`@agentmux_color_{blocked,done,delegating,working,idle,project,agent,text,fg,dim,sidebar_bg}`.

Runtime: `@agentmux_on` (sidebar wanted), `@agentmux_owner` (client whose current window
the sidebar follows).

## Rendering rules (all fork-free)

- A pane's state counts only while `pane_current_command` is not a shell
  (`-?(zsh|bash|fish|sh|dash|ksh|nu)`), which self-heals a `kill -9`'d agent. The sidebar
  keeps a row for 15 s after the shell is back so a normal exit does not flicker.
- A state older than `@agentmux_ttl` renders as idle.
- Window badge: ladder over all panes in the window. Label and timer follow the active pane
  when it is a live agent, else the first live agent pane in the window.

## Terminal title

With `@agentmux_titles on` (the default) the plugin sets `set-titles on` and
`set-titles-string "#{E:@agentmux_title_human}"`, which reads `session:window`, plus
` - agent blocked` or ` - agent done` while any agent on the server is in that state. `off`
leaves both options to your config, which can still embed the public fragment
`#{E:@agentmux_title_human}` in a title of its own.

## Sidebar placement

The sidebar follows the owner client (`@agentmux_owner`) from window to window, except into
a window that is zoomed, narrower than `@agentmux_width + 30` columns, or skipped. There it
waits in the window it was in until the owner reaches one it may use.

`@agentmux_sidebar_skip` is a format evaluated for the owner's current window, so for that
window's active pane. While it is true the sidebar is removed from that window and not
followed into it, and `@agentmux_on` stays `1`. The window, pane, session and
`pane-title-changed` hooks re-run `@agentmux_ensure_or_layout`, which re-creates the sidebar
as soon as the owner's window stops matching. agentmux knows nothing about what the format
means; for example, a nested tmux that marks the title it sends can be kept clear of the
sidebar with `set -g @agentmux_sidebar_skip '#{m:tmux@*,#{pane_title}}'`.

## Scratch directory (hook side, source of truth)

`${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/agentmux-$USER/<server-pid>/<pane>/`

| file | content |
|---|---|
| `gen` | turn counter (bumped on `UserPromptSubmit`) |
| `main` | `running\|stopped` |
| `blocked` | `<detail>\|<tool>\|<tool_use_id>` or empty |
| `detail` | prompt excerpt or `resuming` |
| `start` | epoch of the current turn (`NOW` until the next tmux round-trip, or `date +%s` in **none** mode, replaces it), empty when idle |
| `state` | last derived state (for notification transitions only) |
| `outer` | hop cache `sock\|pane\|client_tty` (omnigent) |
| `subs/<gen>.<agent_id>.s` / `.e` | sub-agent started / ended markers |

`derive()`: blocked file non-empty -> `blocked`; `main == running` -> `working`; live
sub-agents > 0 -> `delegating`; `start` non-empty -> `done`; else `idle`.

## Event transitions

| event | markers | result |
|---|---|---|
| `SessionStart` (`startup\|resume\|clear`; `compact`/`fork` ignored) | wipe dir, `gen=0`, `main=stopped` | idle |
| `UserPromptSubmit` | `gen++`, `main=running`, blocked cleared, detail=excerpt, `start=now` | working |
| `PreToolUse` `AskUserQuestion\|ExitPlanMode` (Claude), `request_user_input` (Codex) | blocked=`question\|plan review` + id | blocked, notify |
| `PermissionRequest` | blocked=`permission <tool>` + id | blocked, notify |
| `Notification` `elicitation_*` / `agent_needs_input` | blocked without id | blocked, notify |
| `Notification` `idle_prompt` | if derived is working (missed Stop): `main=stopped` | derive |
| `PostToolUse` / `PostToolUseFailure` | clear blocked iff the id matches, or the record has no id, or the payload has no `agent_id` (main agent moved on) | derive |
| `Stop` | `main=stopped`, blocked cleared | delegating if sub-agents live, else done (idle if viewed); notify on done when not viewed |
| `SubagentStart` | `.s` marker, `main=running` | working |
| `SubagentStop` | `.e` marker; if main stopped and none live: `main=running`, detail=`resuming` | working / delegating |
| `Interrupt` (Codex) | `main=stopped`, blocked and start cleared | idle |
| `SessionEnd` | unset every option, wipe dir | gone |

## Display-pane resolution

An agent outside tmux (`$TMUX` or `$TMUX_PANE` empty) has nothing to show it on, so the hook
exits before reading its input. Otherwise `sock=${TMUX%%,*}`. Matches `*/tmux-[0-9]*/*` ->
**direct** (`$TMUX_PANE`). Anything else (omnigent's private server) -> **hop**: take the
first non-control client tty of that server and find the pane with that `pane_tty` on every
`${TMUX_TMPDIR:-/tmp}/tmux-*/*` server; not found -> try other
`${TMPDIR:-/tmp}/omnigent-terminal-*/tmux.sock` servers (nested, depth <= 3). No client at
all (web-only), or still no pane -> **none**: the markers advance, nothing is published, and
`SessionEnd` still wipes the directory. The hop result is cached in `outer` and validated on
every event (tty match, non-shell command); `SessionStart`/`UserPromptSubmit` always
re-resolve.

## Redraw signalling

Every writer ends with `refresh-client -S` per attached client and `wait-for -S
agentmux-redraw`; the sidebar renderer blocks on `wait-for agentmux-redraw` and repaints
within ~30 ms. Formats that flip options (`@agentmux_seen`) end with the same signal.
