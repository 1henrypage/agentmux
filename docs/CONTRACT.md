# agentmux data contract

Everything agentmux does flows through three channels: **pane options** on the tmux server
that displays an agent, an **AGX1 title** carried over ssh in OSC 2, and a **scratch
directory** the hook keeps as its source of truth. This file is the contract between the
pieces (`hooks/agentmux-hook`, `agentmux.tmux`, `bin/agentmux`, `agentmux/sidebar.py`,
`agentmux/title_changed.py`). Change it here first.

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
| `@agentmux_host` | this server's host name | `@agentmux_hostname` override, else `#{host_short}` |
| `@agentmux_sidebar` | `1` on the sidebar pane | set by `ensure` and by the renderer |

`SessionEnd` unsets all of them (`set -pu`).

### Remote summary (written by `bin/agentmux title-changed` on ssh panes)

| option | meaning |
|---|---|
| `@agentmux_r_host` | host in the AGX1 header |
| `@agentmux_r_n` | number of decoded entries (self-echo removed) |
| `@agentmux_r_worst` | ladder over all entries |
| `@agentmux_r_worst2` | ladder excluding `done` (used once seen) |
| `@agentmux_r_deleg` | sub-agent count of the first delegating entry |
| `@agentmux_r_proj`, `_r_kind`, `_r_start` | label/timer values of the entry the badge shows |
| `@agentmux_r_exp` | epoch after which the summary is stale (`0` = never, one-shot writer) |
| `@agentmux_r_seen` | `1` once the window was viewed and no new `done` entry arrived since |
| `@agentmux_r_done` | space-separated `host:target` keys of the done entries (seen bookkeeping) |
| `@agentmux_r_prev` | last decoded title (skip duplicates) |
| `@agentmux_r_notified` | `host\|target\|start\|state\|updated` of the last notification (flap guard) |

## Global options

Set by the user before `run tpm`; the plugin fills in defaults.

`@agentmux_width` (46), `@agentmux_key` (`a`, `off` to skip the binding),
`@agentmux_titles` (`auto|human|off`), `@agentmux_notify` (`on|off`),
`@agentmux_notify_done` (`on|off`), `@agentmux_ttl` (14400 s),
`@agentmux_sidebar_density` (`full|compact`), `@agentmux_hostname` (override for
`#{host_short}`), and the twelve colours `@agentmux_color_{blocked,done,delegating,working,
idle,project,agent,remote,text,fg,dim,sidebar_bg}`.

Runtime: `@agentmux_on` (sidebar wanted), `@agentmux_owner` (client whose current window
the sidebar follows).

## Rendering rules (all fork-free)

- A pane's local state counts only while `pane_current_command` is not a shell
  (`-?(zsh|bash|fish|sh|dash|ksh|nu)`), which self-heals a `kill -9`'d agent. The sidebar
  keeps a row for 15 s after the shell is back so a normal exit does not flicker.
- A state older than `@agentmux_ttl` renders as idle.
- A remote summary counts only while `@agentmux_r_exp` is `0` or in the future.
- Window badge: ladder over all panes in the window. Label and timer follow the active pane
  when it is a live agent, else the first live agent pane in the window.

## AGX1 title grammar

```
AGX1|h=<host>|t=<epoch/60>|hb=<60|0>~ ( ENTRY ~ )*
ENTRY := h=<host>|s=<state>|k=<kind>|p=<project>|b=<start>|n=<subs>|u=<updated>
         |x=<0|1>|w=<session:window.pane>|d=<detail>
```

Printable ASCII only; `| ~ ; # % ,` never appear inside data (`p`/`d` are sanitised to
`[A-Za-z0-9 ._@+()-]`, `w` to `[A-Za-z0-9:._-]`, `d` capped at 32). Every entry ends with
`~`; a trailing segment without `~` is a truncated entry and is dropped. `x=1` marks the entry
you would see looking at the pane carrying the title. `hb=60` means the writer re-emits at
least once a minute (a tmux server running the plugin), `hb=0` a one-shot writer (the hook
in bare-ssh mode, `w=` empty). A server re-embeds the entries decoded from its own ssh panes
verbatim, rewriting `x=1` to `x=0` when the embedding pane is not visible.

The title is only emitted to a client whose `client_termname` starts with `tmux` or
`screen` (an inner tmux talking to an outer one); every other client gets the human title
`session:window[ - agent blocked| - agent done]`.

## Scratch directory (hook side, source of truth)

`${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/agentmux-$USER/<server-pid|nosrv>/<pane|session>/`

| file | content |
|---|---|
| `gen` | turn counter (bumped on `UserPromptSubmit`) |
| `main` | `running\|stopped` |
| `blocked` | `<detail>\|<tool>\|<tool_use_id>` or empty |
| `detail` | prompt excerpt or `resuming` |
| `start` | epoch of the current turn (`NOW` until the first tmux round-trip resolves it), empty when idle |
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

`sock=${TMUX%%,*}`. Matches `*/tmux-[0-9]*/*` -> **direct** (`$TMUX_PANE`). Empty ->
**bare**: emit a one-shot title to `/dev/tty` when `SSH_CONNECTION`/`SSH_TTY` is set or
`AGENTMUX_TITLE=1`. Anything else (omnigent's private server) -> **hop**: take the first
non-control client tty of that server and find the pane with that `pane_tty` on every
`${TMUX_TMPDIR:-/tmp}/tmux-*/*` server; not found -> try other
`${TMPDIR:-/tmp}/omnigent-terminal-*/tmux.sock` servers (nested, depth <= 3); still not
found -> **title** mode on that tty. No client at all -> web-only, markers only. The hop
result is cached in `outer` and validated on every event (tty match, non-shell command);
`SessionStart`/`UserPromptSubmit` always re-resolve.

## Redraw signalling

Every writer ends with `refresh-client -S` per attached client and `wait-for -S
agentmux-redraw`; the sidebar renderer blocks on `wait-for agentmux-redraw` and repaints
within ~30 ms. Formats that flip options (`@agentmux_seen`) end with the same signal.
