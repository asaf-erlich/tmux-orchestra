# Changelog

Changes in the [asaf-erlich/tmux-orchestra](https://github.com/asaf-erlich/tmux-orchestra)
fork since it branched from
[gauravmm/tmux-orchestra](https://github.com/gauravmm/tmux-orchestra) `main`.
All of them are on the `fix-pane-exists` branch.

## Unreleased

### Added

- **Resume Claude sessions after a tmux crash.** The Claude Code hook now
  records each pane's session id (`@ab_session_id`). New
  `bin/orchestra-resurrect` saves the pane → session map to a state file
  (`@orchestra_state_file`, default
  `${XDG_STATE_HOME:-~/.local/state}/tmux-orchestra/sessions`) from
  tmux-resurrect's `@resurrect-hook-post-save-all`, and on
  `@resurrect-hook-post-restore-all` marks the matching panes that run no
  Claude as resumable (`@ab_resume_id`). The sidebar lists them dim as
  `↺ resume` with the last prompt, and Enter or a click types
  `claude --resume <id>` into the pane. `orchestra.tmux` installs both hooks,
  appending to ones already set. This is the one exception to "tmux options
  are the only state store".

- **Orphaned sessions section.** Interactive Claude Code sessions that run in
  no tmux pane (for instance left behind when tmux crashed before they were
  saved) are listed under a `── orphaned ──` separator after the background
  sessions, titled by directory, from the same `claude agents --json` refresh.
  Enter or a click resumes one in the matching shell pane or a new window; one
  whose process still runs asks before it is killed
  (`bin/orchestra-orphan-resume`). `x` dismisses a row
  (`@orchestra_orphan_dismissed`); `@orchestra_orphans off` hides the section.

### Changed

- **The sidebar always sits at the left edge of its window, full height.**
  It used to open and follow to the left of the focused pane, so with two
  panes side by side it ended up between them whenever the right one was
  focused. `orchestra-follow` and `orchestra-toggle` now place it with
  `-f`, so it spans the window's full height at the far left whichever
  pane is focused.

### Fixed

- **An early SIGUSR1 no longer kills a new sidebar renderer.**
  `orchestra-toggle` stored the pane's pid right after `split-window`, when
  it is still the pane's shell (and later the renderer while it sourced its
  libraries), and a hook (`window-renamed`, fired when the pane's command
  changes) could signal it before `orchestra-render` had a `USR1` trap, so
  the default action killed the sidebar (about one run in four of the
  "follow moves the sidebar" test). `orchestra-render` now traps `USR1` on
  its first line and then stores its own pid in `@orchestra_sidebar_pid`;
  `orchestra-toggle` no longer stores one, so no hook signals the pane
  before it can survive the signal.

- **A pane no longer stays in "background" after its background work
  finished.** The Stop hook is the only hook that lists background tasks, so
  a task that finished during that turn's own wrap-up, or was killed, left
  the pane at `N background: ...` until the next prompt: no further turn
  meant no further Stop, and the periodic `reconcile` only cleared
  running/waiting. Stop now records the ids of the tasks it counted
  (`@ab_bg_tasks`), and `reconcile` ends a `background` pane whose session
  has been idle for 3 seconds once the transcript holds a finished
  `<task-notification>` for every one of them (done, with the unread dot
  unless you are looking). Limit: a task id with no recorded notification
  (a Stop payload without ids) is left alone.
- **A daemon-hosted Claude session no longer shows on the other panes of its
  window.** Hooks of a session the Claude daemon hosts (`claude --bg`, then
  `claude attach`) get no `$TMUX_PANE`, so they write window-scoped options,
  and every pane without a value of its own inherited them: a second Claude
  pane in the window showed the same notification and row text. A pane's
  hooks, `backfill` and the renderer's `reconcile` now give the pane empty
  values of its own for the agent options, and `clear_opt` empties them on a
  pane instead of unsetting, so the window's values stay hidden. The hook no
  longer clears the window's agent options, which wiped that session's state.
- **Clicks select the row under the mouse.** The renderer reads one
  `|`-separated line per pane, so a `|` or a newline in a pane's free text
  (a Bash command with a pipe, a multi-line command) shifted its fields or
  split its line, and the pane's row disappeared. Clicks and the keyboard
  selection still counted that pane, so every row below it selected the
  one above. The renderer now shows `|` in free-text fields as `¦` and
  newlines as spaces.
- **An agent-team teammate no longer keeps a pane in "background".**
  Claude Code lists a teammate in the Stop hook's `background_tasks` as
  `"type": "teammate", "status": "running"` for its whole life, also while
  it sits idle waiting to be messaged, so the `idle` check below never
  matched it and the pane went back to the background color after every
  turn. Teammates are now left out of the count; one that messages back
  starts a new turn, which marks the pane running again.
- **An idle background agent no longer keeps a pane in "background".**
  The Stop hook treated every background task whose status was not a
  finished one as running work, so a teammate sitting idle waiting for a
  message (`"status": "idle"`) left the pane spinning with
  `1 background: <its goal>` indefinitely. Idle tasks now count as not
  running, and the turn ends as done.
- **Pane sizes no longer drift as the sidebar comes and goes.** Entering a
  window took the sidebar's columns from all its panes, and leaving gave
  them all to the left-most one, so every follow or toggle moved width
  from the right pane to the left. The sidebar now saves the window's
  layout when it enters (`@orchestra_layout_before` /
  `@orchestra_layout_with`) and puts it back with `select-layout` when it
  leaves, unless you resized or added or removed panes meanwhile.
- **Row numbers for split Claude panes stay put.** Rows were titled with
  the pane index, which shifted by one whenever the left-edge sidebar
  (pane 0) entered or left the window. They are now numbered `.1`, `.2`
  by position among the window's Claude panes.

### Added

- **A row for each Claude pane.** Two Claude Code sessions split into one
  window used to share that window's state (the last hook to write won)
  and one sidebar row. The Claude Code hook now writes its state to its
  own pane, and the sidebar draws one row per Claude pane, titled
  `session:window.<n>` (1, 2, ... in pane order) when a window has
  several (a window with one keeps `session:window`). Enter or a click selects that pane, also
  from another window (the focus hook no longer moves focus back to the
  window's previously active pane). Every
  `orchestra` subcommand takes `--pane %N` to write pane options; without
  it they stay window-scoped, so OpenCode, the prompt hooks and your own
  scripts work as before. Window-level state from the earlier version is
  cleared the next time Claude starts a session or a turn (or by
  `orchestra-claude-hook backfill`), so another pane in that window may
  show no prompt until its next turn. A new or cleared session now records
  its start time, so its age counts up instead of following the window's
  activity. After upgrading, reload the plugin
  (`tmux run-shell /path/to/tmux-orchestra/orchestra.tmux`, or re-source
  your tmux.conf) so focusing a pane clears its own unread mark; until
  then the old focus hook clears only the window's, and a pane's green
  check and unread dot stay. Then restart the sidebar (`prefix + B`
  twice).
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
