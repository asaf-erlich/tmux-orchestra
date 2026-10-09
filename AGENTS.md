# AGENTS.md — tmux-orchestra

## Project overview

tmux-orchestra is a pure POSIX shell tmux plugin that renders a live sidebar pane (one per tmux server) showing, for each window running Claude Code in any session, the agent state (running/waiting/done), status pills, progress bars, and notifications. State flows exclusively through tmux user-options (`@ab_*`); there are no daemons, sockets, or files outside tmux itself. The renderer polls every 125 ms and wakes early on SIGUSR1.

## Repository layout

```
orchestra.tmux          TPM entrypoint — init, hooks, keybindings
bin/
  orchestra             CLI dispatcher (set-status, notify, set-state, …)
  orchestra-render      Long-lived sidebar TUI (125 ms polling loop)
  orchestra-toggle      Open/close the one global sidebar
  orchestra-follow      Move sidebar pane to the focused window, any session
  orchestra-notify      Platform-detecting notifier shim
  orchestra-click       Map a sidebar click to select-window / switch-client
  orchestra-select      Move/confirm the sidebar keyboard selection
  orchestra-claude-hook Claude Code hook dispatcher (JSON on stdin) + backfill
  orchestra-bg-refresh  Poll `claude agents --json` into @orchestra_bg_agents
lib/
  common.sh             Option CRUD, window resolution, shared helpers
  select.sh             Claude-window filter, keyboard selection, click mapping
  render.sh             Pure rendering (boxes, glyphs, progress, ANSI)
  notify.sh             Platform notifier dispatch (Linux/macOS/WSL)
hooks/
  prompt.bash           Bash shell integration (cwd/branch/exit/cmd)
  prompt.zsh            Zsh shell integration
  claude-code/          Hook template for Claude Code (.claude/settings.json)
  opencode/             Hook plugin for OpenCode (orchestra.js, Bun)
  codex/                Stub — unimplemented pending Codex hook API
tests/
  test_cli.sh           Integration tests (spins up isolated tmux server)
  test_render.sh        Fixture-based render regression tests
  test_select.sh        Click/selection mapping against a stub tmux function
  fixtures/             Pipe-delimited input + .expected output pairs
spec/
  implementation-spec.md  Authoritative design reference
  planning-spec.md        Design rationale and tradeoffs
  FUTURE.md               Planned v0.2+ features (do not implement now)
Makefile                `make test` (shellcheck + both test suites)
README.md               User-facing installation and quick-start guide
```

## Language and shell constraints

- **Pure POSIX sh only.** No bash-isms (`[[`, arrays, `local` outside functions, `$(< file)`, etc.). Every `.sh` file and every `bin/` script must pass `shellcheck -s sh`.
- No compiled dependencies, no build step, no runtime deps beyond tmux ≥ 3.4.
- All scripts begin with `#!/usr/bin/env sh` (or are sourced; check existing header conventions before changing).

## tmux option schema (authoritative)

All persistent state is stored as tmux user-options. Window-scoped unless noted, or pane-scoped when written with `--pane %N`: the Claude Code hook writes every `@ab_*` option to its own pane (`$TMUX_PANE`), so each Claude pane has its own state and sidebar row. `#{@ab_*}` in formats inherits pane → window → session → global, so a pane without a value of its own shows its window's (OpenCode and the prompt hooks still write window options). The hook gives its pane an empty value of its own for each agent option (`AB_AGENT_OPTS` in lib/common.sh, `shadow_pane_agent_opts`) at SessionStart and UserPromptSubmit, and `clear_opt` empties those options on a pane instead of unsetting them, so window-scoped state (the earlier version's, or a daemon-hosted session's whose hooks have no `$TMUX_PANE`) is not inherited by a pane with its own hooks. Sidebar state is global (`set-option -g`): there is one sidebar per server.

| Option | Writer | Max | Notes |
|---|---|---|---|
| `@ab_agent_state` | harness hook | — | `running` \| `waiting` \| `background` \| `compacting` \| `error` \| `done` \| empty |
| `@ab_current_action` | harness hook | 120 chars | Tool name or prompt text |
| `@ab_last_prompt` | `orchestra set-prompt` | 120 chars | Last prompt sent to the agent; survives `clear-state` |
| `@ab_session_source` | `orchestra-claude-hook` | — | `clear` \| `startup` \| `empty` \| `agents` while no prompt since then; unset after a prompt |
| `@ab_finished_at` | `orchestra set-state` | — | Epoch seconds of the last `done`, or of a `waiting` that interrupted `running` |
| `@ab_status_<key>` | `orchestra set-status` | 40 chars | Arbitrary status pill value |
| `@ab_status_<key>__icon` | `--icon` flag | 1 grapheme | Optional pill icon |
| `@ab_status_<key>__color` | `--color` flag | 32 chars | `#rrggbb` or ANSI name |
| `@ab_progress` | `orchestra set-progress` | — | Float [0, 1] |
| `@ab_progress_label` | `--label` flag | 60 chars | Progress bar label |
| `@ab_unread` | `orchestra notify` | — | `1` or empty; cleared on focus-in |
| `@ab_last_notification` | `orchestra notify` | 120 chars | `title — subtitle: body` |
| `@ab_branch` | prompt hook | — | `git symbolic-ref --short HEAD` |
| `@ab_cwd` | prompt hook | — | `$PWD` |
| `@ab_last_cmd` | prompt hook | 80 chars | Last shell command |
| `@ab_last_exit` | prompt hook | 32 chars | Last exit code |
| `@orchestra_sidebar_width` | orchestra-toggle, after-resize-pane hook | — | Global: cached pane width |
| `@orchestra_sidebar_pane_id` | orchestra-toggle | — | Global: the sidebar pane ID |
| `@orchestra_sidebar_pid` | orchestra-toggle | — | Global: renderer PID |
| `@orchestra_selected_window` | lib/select.sh | — | Global: sidebar keyboard selection (pane_id, or `bg:<id>` for a background session); unset = the viewing session's active window's active Claude pane (else its previously active pane, else its first Claude pane) |
| `@orchestra_layout_before` / `@orchestra_layout_with` | orchestra-follow, orchestra-toggle | — | Window: its layout just before and just after the sidebar entered; restored with `select-layout` when the sidebar leaves if the layout is still the "with" one (`sidebar_layout_save` / `sidebar_layout_restore` in lib/common.sh) |
| `@orchestra_bg_agents` | orchestra-bg-refresh | — | Global: background Claude sessions, `id;state;started_at;cwd;name` records joined by `\|`; unset when none |
| `@orchestra_bg_id` | window opened by `select_bg_open` | — | Window: the background session id this window runs `claude attach` for |
| `@orchestra_background` | user | — | Global: `off` hides background sessions |
| `@orchestra_bg_interval` | user / orchestra.tmux | — | Global: background refresh period in seconds (default 10, 0 disables); read when the renderer starts |

Earlier versions kept per-session `@ab_width`, `@ab_sidebar_pane_id`, `@ab_sidebar_pid` and `@ab_selected_window`; `orchestra.tmux` closes those sidebars and unsets the options on load.

`set_opt` / `clear_opt` / `get_opt` in [lib/common.sh](lib/common.sh) are the only correct way to read/write the window options (the global sidebar options hold ids and numbers and are written directly with `set-option -g`). They enforce truncation and prefix namespacing. Do not call `tmux set-option` directly for `@ab_*` options.

## CLI interface (bin/orchestra)

```
orchestra set-status <key> <value> [--icon GLYPH] [--color COLOR]
orchestra clear-status <key>
orchestra list-status
orchestra set-progress <float> [--label TEXT]
orchestra clear-progress
orchestra notify --title T [--body B] [--subtitle S] [--quiet]
orchestra set-state <running|waiting|background|compacting|error|done> [--action TEXT]
orchestra clear-state
orchestra set-prompt <text>
```

All subcommands accept `--window <id>` to target a specific window, or `--pane <%id>` to write pane options instead (`resolve_target` in [lib/common.sh](lib/common.sh)); `set_opt` / `clear_opt` / `get_opt` pick `-p` for a `%N` target and `-w` otherwise, and `get_opt` reads the target's own value only. Without either, window resolution falls through four steps (see `resolve_window` in [lib/common.sh](lib/common.sh)): explicit flag → `$TMUX_PANE` → `$ORCHESTRA_WINDOW_ID` → current window.

Exit codes: `0` success, `1` usage error, `2` not in tmux, `3` tmux call failed.

## Renderer (bin/orchestra-render and lib/render.sh)

- `orchestra-render` runs in the sidebar pane. It reads all window state in **one** tmux call per tick (`tmux display-message ... \; list-panes -a -F '...'`, one line per pane of every session with a Claude flag), then calls `render_frame` (pure, one awk process, in [lib/render.sh](lib/render.sh)). Process creation is slow on some hosts, so keep the tick at one tmux call plus one awk and never fork per window or field.
- Do not add tmux calls inside `render_rows`/`render_frame` or the awk program — rendering must remain pure.
- The pipe-delimited format read from tmux is:
  `session_name|window_id|window_name|window_active|state|action|branch|cwd|last_cmd|progress|progress_label|unread|last_notification|phase|phase_icon|phase_color|spinner|selected_window|sidebar_focused|claude|finished_at|window_activity|session_source|pane_id|pane_index|pane_active|last_prompt`
  `pane_active` is 1 for the window's active pane, 2 for its previously active pane (`pane_last`), else 0. `last_prompt` is last because it may contain `|`; the awk rejoins fields 27 onward. Lines without pane fields (older fixtures) render one block per window.
- Idle windows show the finish age (`now`, `5m`, `3h`, `2d`, `6w`; from `@ab_finished_at`, else `window_activity`) at the right of the top border: bold under an hour, grey past a day, hidden while running. The last prompt (`❯ …`) takes the activity row when idle and the meta row while running or waiting; an idle window with `@ab_session_source` and no prompt shows a dim `∅ cleared` / `∅ empty session`. The last notification is only a meta-row fallback.
- Claude panes from every session are listed, one block each, in session-name, window-index then pane-index order, titled `session:window`, or `session:window.<n>` when the window has several Claude panes (`n` is the pane's 1-based position among that window's Claude panes, not its `pane_index`, which shifts as the left-edge sidebar enters and leaves); only one pane of the sidebar's own session's active window is drawn active: its active pane, else its previously active one, else its first Claude pane. Only panes running Claude Code are listed (`pane_current_command` is the version-named binary, e.g. `2.1.280`, or `claude`). The filter lives in one place, `ORCHESTRA_CLAUDE_PANE` / `select_windows` in [lib/select.sh](lib/select.sh); the render awk dedupes pane lines by pane id, and keyboard selection and `orchestra-click` index the same filtered list (Enter and clicks run `select-window` and `select-pane` on the pane, after `switch-client` for another session). Focusing a pane clears its own `@ab_unread` (and its window's).
- Each state has a color (`state_color` in lib/render.sh): running uses its spinner's color (Claude orange), the rest come from `@orchestra_wait_color`, `@orchestra_background_color`, `@orchestra_compacting_color`, `@orchestra_error_color` and `@orchestra_done_color` (defaults in orchestra.tmux and `set_state_colors`), passed to `render_frame` as header fields 3 and 6-9. Idle windows with an unread finish draw their rows in the done color, with a `✓` under Nerd Fonts.
- Animated glyphs (running: `⠋⠙⠹⠸`, waiting: `◐◓◑◒`, background: `◴◷◶◵`, compacting: `◜◝◞◟`) rotate via `FRAME_INDEX` incremented each tick. ASCII fallbacks exist for `TERM=dumb` or `NO_COLOR=1`.
- Stuck states: rejecting a permission prompt or pressing Esc ends a turn with no hook. The same background job first runs `orchestra-claude-hook reconcile`, which clears running/waiting on each Claude pane (its own options, or its window's when it has none) whose `~/.claude/sessions/<pid>.json` has had `status: "idle"` for at least 3 seconds (`statusUpdatedAt`).
- Background sessions: `claude agents --json` starts a node process, so it never runs on the tick. `orchestra-render` starts `orchestra-bg-refresh` as a background job every `@orchestra_bg_interval` seconds (one at a time); it writes `@orchestra_bg_agents` only when the list changed and then sends SIGUSR1. The tick reads the option as a last `|bg|REC|...` line of the same tmux call. `render_frame` draws a one-line `── background ──` separator and one 3-line `bg_block` per session after the windows (after the one-line placeholder when there are none); `select_row` uses the same geometry, and `select_go` on a `bg:<id>` pick calls `select_bg_open`, which selects the window tagged `@orchestra_bg_id=<id>` or opens a new one running `claude attach <id>`.
- Nerd Font glyphs are gated on `@orchestra_nerd_fonts on|off` (no auto-detection).

## Testing

```sh
make test          # shellcheck + test_cli.sh + test_render.sh
make shellcheck    # shellcheck only
```

- `tests/test_cli.sh` spins up a detached tmux server on a private socket (`-L <socket>`), exercises every CLI subcommand, and asserts option values are written correctly. Always clean up the server with `tmux -L <socket> kill-server` at the end.
- `tests/test_render.sh` sources [lib/render.sh](lib/render.sh), feeds fixture data, and diffs stdout against [tests/fixtures/](tests/fixtures/) `.expected` files.
- **When adding a feature, add a corresponding test.** For rendering changes, add or update `.expected` fixture files.

## Pull requests

PRs go to the fork, `asaf-erlich/tmux-orchestra`, against `main`. Every PR that changes behavior must also update, in the same PR:

- [CHANGELOG.md](CHANGELOG.md): an entry under `## Unreleased` (`Added` / `Changed` / `Fixed`).
- [README.md](README.md): the "What this fork adds" bullet list, plus any section whose instructions or options changed.
- All tests must pass and shellcheck must be clean before a change is complete.

## Key conventions

### Option writes
Always go through `set_opt` / `clear_opt`. These enforce max-length truncation (trailing `…`) and correct tmux scope. Direct `tmux set-option -w @ab_*` calls bypass truncation and break renderer assumptions.

### Batched tmux calls
Prompt hooks batch multiple `set-option` calls with `\;` into one `tmux` invocation to minimize shell-prompt overhead. Follow this pattern whenever writing multiple options from a time-sensitive path.

### No new persistent state outside tmux options
Do not introduce temp files, FIFOs, sockets, or environment variables as a persistence mechanism. All cross-process communication goes through `@ab_*` options and SIGUSR1.

### SIGUSR1 wakeup
After writing state that should appear immediately in the sidebar (e.g., `notify`), send `kill -USR1 <renderer_pid>` where pid comes from `@orchestra_sidebar_pid`. The renderer may not be running (sidebar closed) — handle that case silently.

### Sidebar pane lifecycle
The sidebar is a real tmux pane running `orchestra-render`. There is one per server. `orchestra-follow` moves the pane across windows and sessions via `move-pane -f` (left edge, full window height, whichever pane is focused; `orchestra-toggle` opens it with `split-window -f` likewise) on every `pane-focus-in` and `client-session-changed`, and clears the global options if the pane is gone. Entering a window takes the sidebar's columns from all its panes and leaving gives them to the left-most one, so both scripts save the window's layout on entry and put it back on exit when nothing else changed (`@orchestra_layout_before` / `@orchestra_layout_with`); otherwise each visit would shift width from right to left. The renderer PID stays alive across moves; always signal via `@orchestra_sidebar_pid`, not by searching process trees.

## Agent harness integration pattern

New harness templates belong in `hooks/<name>/` and follow this contract:
1. Map "agent is working" events → `orchestra set-state running --action "<tool>"`.
2. Map "agent needs input" events → `orchestra set-state waiting --action "<prompt>"`.
3. Map "agent finished" events → `orchestra set-state done && orchestra clear-state`.
4. For significant events → `orchestra notify --title "…" --body "…"`.
5. Document in a `README.md` inside the hooks directory.
6. Never depend on non-standard binaries in the core path (jq is optional, used only in Claude Code template).

## What not to implement (v0.1 scope)

The items in [spec/FUTURE.md](spec/FUTURE.md) are explicitly deferred. Do not implement:
- Per-window color theming or arbitrary multi-pill rendering.
- Pane-border unread indicators.
- Compact statusline integration.
- State dump/restore.
- Fish or PowerShell prompt hooks.
- Real-time tmux hook on arbitrary option writes (not achievable without polling).

## Quick orientation for common tasks

| Task | Where to look |
|---|---|
| Add a new CLI subcommand | `bin/orchestra` — add `cmd_<name>()` and a `case` branch |
| Change rendering layout | [lib/render.sh](lib/render.sh) — awk `window_block`, `render_rows`, `render_frame` |
| Add a platform notifier | [lib/notify.sh](lib/notify.sh) — extend `orchestra_notify_dispatch` |
| Change default config/keys | [orchestra.tmux](orchestra.tmux) — top-level option and bind-key calls |
| Add a new harness template | `hooks/<name>/` — template files + README |
| Debug option state | `tmux show-options -w @ab_*` in the target window |
| Trace renderer input | `tmux list-panes -a -F '...'` (copy format from `orchestra-render`) |
