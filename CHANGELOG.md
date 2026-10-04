# Changelog

Changes in the [asaf-erlich/tmux-orchestra](https://github.com/asaf-erlich/tmux-orchestra)
fork since it branched from
[gauravmm/tmux-orchestra](https://github.com/gauravmm/tmux-orchestra) `main`.
All of them are on the `fix-pane-exists` branch.

## Unreleased

### Added

- **A row for each Claude pane.** Two Claude Code sessions split into one
  window used to share that window's state (the last hook to write won)
  and one sidebar row. The Claude Code hook now writes its state to its
  own pane, and the sidebar draws one row per Claude pane, titled
  `session:window.<pane index>` when a window has several (a window with
  one keeps `session:window`). Enter or a click selects that pane, also
  from another window (the focus hook no longer moves focus back to the
  window's previously active pane). Every
  `orchestra` subcommand takes `--pane %N` to write pane options; without
  it they stay window-scoped, so OpenCode, the prompt hooks and your own
  scripts work as before. Window-level state from the earlier version is
  cleared the next time Claude starts a session or a turn (or by
  `orchestra-claude-hook backfill`), so another pane in that window may
  show no prompt until its next turn. A new or cleared session now records
  its start time, so its age counts up instead of following the window's
  activity. Restart the sidebar after upgrading
  (`prefix + B` twice).
- **Background Claude Code sessions in the sidebar.** Sessions run by the
  Claude Code daemon (`claude --bg`, sent to the background from an
  interactive session, or launched from FleetView) run in no tmux pane, so
  the sidebar never showed them. They are now listed under a
  `── background ──` separator with their name, state and directory. Enter
  or a click opens one in a new window, in its directory, running
  `claude attach <id>`. While that window is open the session shows as a
  normal window; detaching closes it. The list comes from
  `claude agents --json`, polled in the background every
  `@orchestra_bg_interval` seconds (default 10). Set
  `@orchestra_background off` to hide it.
- **One sidebar for the whole server.** The sidebar lists Claude windows
  from every session, titled `session:window`, and follows focus across
  sessions. Enter or a click on a window in another session switches your
  client there. Loading the plugin removes the old per-session sidebars.
- **Only windows running Claude Code are listed.** Windows where Claude
  exited without its Stop hook no longer show stale state (such as a
  spinner that never stops). With no Claude windows the sidebar shows
  "no claude sessions".
- **Keyboard selection.** With the sidebar focused, Up/Down (or `j`/`k`,
  or the mouse wheel) move a highlight across windows without switching,
  and Enter opens the highlighted one.
- **Finish age and last prompt.** Idle windows show how long ago the agent
  finished (`now`, `5m`, `3h`, `2d`, `6w`) in the top border: bold under an
  hour, grey past a day. The last prompt (`❯ …`) is shown on the window,
  from the new `orchestra set-prompt` subcommand.
- **Empty-session marker.** An idle window with no prompt since `/clear` or
  a fresh start shows a dim `∅ cleared` or `∅ empty session`.
- **Demo script.** [DEMO.md](DEMO.md) walks through every feature one
  prompt, command or key at a time, using real Claude Code sessions to show
  each agent state.
- **`orchestra-claude-hook`.** One dispatcher for all Claude Code hook
  events replaces the inline `jq` commands in the hook template. The idle
  reminder Claude sends a minute after a turn ends no longer marks the
  window as waiting. `orchestra-claude-hook backfill` fills in state for
  Claude panes that were already running.

- **A color for each agent state.** Working and waiting on you were both
  orange. Each state now has its own color and glyph: working keeps the
  Claude-orange spinner; blocked on you (a permission prompt or question)
  is red; waiting on background work is blue (`◴`, `&` without Nerd
  Fonts); compacting is purple (`◜`, `=`); a turn that ended on an API
  error such as a rate limit is yellow (`✗`, `X`); an idle window that
  finished while you were elsewhere is green, with a `✓` (Nerd Fonts);
  idle windows you have seen stay plain. Set the colors with
  `@orchestra_wait_color`, `@orchestra_background_color`,
  `@orchestra_compacting_color`, `@orchestra_error_color` and
  `@orchestra_done_color`. `orchestra set-state` accepts `background`,
  `compacting` and `error`.
- **Background, compaction and error states from Claude Code.** When a turn
  ends with background agents, shells or monitors still running (the Stop
  hook's `background_tasks`), the window shows `background` with the
  first task instead of finishing. New `stop-failure`, `pre-compact` and
  `post-compact` events in `orchestra-claude-hook` (hooks `StopFailure`,
  `PreCompact` and `PostCompact` in the template) show API errors and
  compaction.

### Changed

- **Waiting color is red.** The default `@orchestra_wait_color` changed
  from amber `#d29922` to red `#f85149`, so it no longer looks like the
  running spinner. A running tmux server keeps the old value until you run
  `tmux set -gu @orchestra_wait_color` and reload the plugin. An open
  sidebar keeps drawing with the code it started with, so close and reopen
  it (`prefix + B` twice) to see the new states.
- **Much faster redraws.** Each redraw is one tmux call and one awk pass
  instead of a process per field and per line. On a macOS host with slow
  process creation, a 9-window redraw went from about 1.5 s to about
  170 ms, and keypresses from 1-4 s to under 0.5 s.

### Fixed

- **API error marked a watched window unread.** The `StopFailure` hook
  marked the window unread even while you were looking at it, so once the
  error cleared it showed the green "finished, not yet seen" check. It now
  skips the unread mark for the window an attached client is showing, as
  Stop and the permission prompt already do.
- **Background task results shown as the last prompt.** When a background
  task finishes, Claude Code submits its result as a prompt starting with
  `<task-notification>`, and the sidebar showed that markup instead of what
  you typed. Prompts that start with `<` no longer replace the last prompt.
- **Window stuck red after rejecting a permission prompt.** Rejecting a
  prompt, or pressing Esc, ends the turn without running any Claude Code
  hook, so the window kept showing "allow? ..." (or the spinner) until the
  next prompt. The sidebar's background refresh now runs
  `orchestra-claude-hook reconcile`, which clears a running or waiting
  window once Claude's session file has reported `idle` for 3 seconds; the
  window goes idle within about `@orchestra_bg_interval` seconds (default
  10). New `post-tool`, `tool-failure` and `permission-denied` events
  (hooks `PostToolUse`, `PostToolUseFailure` and `PermissionDenied` in the
  template) also turn an approved prompt back to running as soon as the
  tool runs.
- **Rejected prompt left the window green.** A permission prompt marked the
  window unread even while you were looking at it, so once it cleared the
  window showed the green "finished, not yet seen" check. The Notification
  hook now skips the unread mark for the window an attached client is
  showing, as Stop already did, and reconcile drops the unread when it
  clears a window.
- **Two Claude panes in one window.** Reconcile cleared the window as soon
  as one of its Claude panes went idle, even while the other was still
  working. Each Claude pane now has its own state, and reconcile clears a
  pane only when its own session has been idle for 3 seconds.
- **Focus loop that could crash the terminal.** `orchestra-follow` resolved
  the "current" window against whichever client tmux picked, which could
  make focus hooks fire each other in a loop. In one case iTerm2 grew to
  22 GB and died. The hook now passes the focused window and pane
  explicitly.
- **Sidebar wedged after its pane closed.** A stale pane id made every
  toggle fail with "failed to close sidebar". Empty `display-message`
  output now counts as a missing pane or window.
- **Cursor walking down the sidebar.** The sidebar pane no longer echoes
  keys or the mouse wheel.
- **"Terminated: 15 sleep" flashing in the sidebar** after a keypress.
- **tmux.conf values overwritten.** `@orchestra_nerd_fonts`,
  `@orchestra_wait_color`, `@orchestra_key` and `@orchestra_width` set in
  tmux.conf before the plugin loads are no longer reset to their defaults.
