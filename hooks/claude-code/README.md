# Claude Code hook template

Merge `settings.json` into `~/.claude/settings.json`. Every event calls
`orchestra-claude-hook <event>` (in `bin/`, on the tmux `PATH` once the plugin
is loaded; use the full path if Claude runs outside a tmux-started shell),
which reads Claude Code's hook JSON on stdin and maps it onto orchestra state:

| Event | Effect |
|---|---|
| `UserPromptSubmit` | stores the prompt (`@ab_last_prompt`), marks running |
| `PreToolUse` | marks running with the tool and its description or main argument |
| `PostToolUse` | a tool ran after a permission prompt: waiting goes back to running |
| `PostToolUseFailure` | an interrupt (Esc, or rejecting a permission prompt) clears state, since no `Stop` follows; other failures act like `PostToolUse` |
| `PermissionDenied` | a rejected tool call clears state; if Claude carries on, its next hook marks running again |
| `Notification` | a permission prompt marks waiting as `allow? <pending tool>`; other prompts mark waiting with Claude's message; the idle reminder Claude sends a minute after a turn ends changes nothing, so finished sessions do not look blocked |
| `Stop` | records `@ab_finished_at`, clears state, marks unread unless an attached client is showing the window; while background tasks (agents, shells, monitors) are still running it marks `background` as `N background: <first task>` instead, since Claude resumes when they finish |
| `StopFailure` | the turn ended on an API error (rate limit, overload, ...): marks `error` as `error: <type>` and notifies |
| `PreCompact` | marks `compacting` |
| `PostCompact` | back to running after automatic compaction; clears state after `/compact` |
| `SessionStart` | `/clear` and fresh starts drop the prompt and set `@ab_session_source` (the sidebar shows `∅ cleared` / `∅ empty session`); resume restores the last prompt from the transcript; compaction changes nothing |
| `SessionEnd` | clears state |

The script always exits 0, so a hook never blocks Claude, and does nothing
outside tmux.

For Claude sessions that were already running before the hooks were
installed, `orchestra-claude-hook backfill` fills in the last prompt, finish
time and empty-session marker from `~/.claude/sessions/<pid>.json` and each
session's transcript, and clears the "waiting" left behind by Claude's idle
reminder.

## Note about jq

The dispatcher uses `jq` because Claude Code provides structured JSON hook
input. `tmux-orchestra` itself does **not** depend on `jq`; only this optional
integration does.
