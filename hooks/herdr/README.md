# herdr customizations

My changes on top of vanilla [herdr](https://github.com/ogulcancelik/herdr), kept here
because most live outside the repo (`~/.config/herdr/config.toml`,
`~/.claude/settings.json`, `~/.zshrc`). Goal: get the tmux-orchestra sidebar's
information (cleared markers, last prompt, finish age, background/compacting/error
state) into herdr's sidebar, and keep tmux muscle memory.

Terminology: tmux session = herdr workspace, tmux window = tab, pane = pane.

## What is in this directory

| File | Role |
|---|---|
| `claude-session-meta.sh` | Claude Code hook. Reads the event JSON on stdin and reports pane metadata tokens to herdr (`herdr pane report-metadata --source orchestra`). Display only; herdr owns agent state. No-op outside herdr (`HERDR_ENV`, `HERDR_PANE_ID`). |
| `age-ticker.sh` | One shared background loop per herdr server (started by the hook, 30 s interval, `ORCHESTRA_AGE_INTERVAL`). Recomputes the `age` token (`now`, `5m`, `3h`, `2d`, `6w`) for every non-working pane from its `finished` epoch token, because herdr cannot recompute tokens itself. Exits after 3 failed `herdr pane list` calls. Needs `jq`. |

Buckets in `age-ticker.sh` match `age_text` in `lib/render.sh`. The background-task
filter in the Stop branch must stay in sync with `RUNNING_TASKS` in
`bin/orchestra-claude-hook`.

## Tokens set by `claude-session-meta.sh`

| Event | Effect |
|---|---|
| SessionStart `clear` | `session=∅ cleared` |
| SessionStart `startup` / empty | `session=∅ empty session` |
| SessionStart `compact` | clears `session` and `state` |
| SessionStart other (resume, fork) | clears `session` |
| UserPromptSubmit | clears `session`, `state`, `finished`, `age`; sets `prompt=❯ <first 120 chars>` |
| Stop | `finished=<epoch>`, `age=now`; `state=N background: <task>` while background tasks run, else clears `state` (needs `jq`) |
| StopFailure | `state=✗ error: <first 24 chars of error>` |
| PreCompact | `state=compacting` (herdr has no compacting state) |

## Claude Code hooks in `~/.claude/settings.json`

- `claude-session-meta.sh` is registered as its own entry (timeout 10) on
  SessionStart, UserPromptSubmit, Stop, StopFailure and PreCompact.
- Inline one-liners, each using its own `--source` so tokens do not clobber each other:
  - UserPromptSubmit and Stop: `last=HH:MM` (`--source claude-last`). Superseded
    visually by `$age`, but still reported.
  - SessionStart: `repo=<git toplevel basename, else cwd basename>` (`--source claude-repo`).
- `~/.claude/hooks/herdr-agent-state.sh session` (installed and managed by herdr's own
  Claude integration, `HERDR_INTEGRATION_ID=claude`) runs on SessionStart. Do not edit it;
  reinstalling overwrites it.
- These sit beside the existing tmux hooks (`bin/orchestra-claude-hook ...`), which keep
  running unchanged.

## `~/.config/herdr/config.toml`

Layout and state:

```toml
[ui.sidebar.spaces]
rows = [["state_icon", "workspace"], ["$repobranch", "git_status"]]

[ui.sidebar.agents]
rows = [["state_icon", "$state", "$repo", "tab", "$age"],
        ["$session", "$prompt"],
        ["terminal_title_stripped"]]
```

- Row 1: icon, then the `$state` token (empty when idle, so the word "idle" is gone and
  the row only speaks when something is notable), repo, tab, finish age.
- Row 2: `$session` (`∅ cleared` / `∅ empty session`) and `$prompt` (`❯ last prompt`),
  same idea as the tmux sidebar's activity row.
- Row 3: Claude's own session title, so same-named agents are distinguishable.
- Spaces rows show `repo:branch` of the most recently active pane.

Other settings: `[ui.toast] delivery = "herdr"`, `[ui.sound] enabled = false`,
`status_indicators = "symbols"`, `sidebar_width = 40`, `sidebar_max_width = 90`,
`theme = "terminal"` with `auto_switch = false`, `onboarding = false`.

Keybindings, ported from `~/.tmux.conf` and `~/.byobu/keybindings.tmux`: prefix is
`ctrl+b` or `f12`; F-keys and Alt-arrows for tab and pane navigation (see the file for
the full table with the tmux/byobu origin of each binding). Not portable and dropped:
synchronize-panes, list-clients, refresh-client, pane swap, next-layout, send-to-all,
tmux-resurrect/continuum (herdr restores sessions itself).

## `~/.zshrc` (shell side, only when run inside herdr)

- `_herdr_tab_repo` (chpwd hook): renames the tab to the git repo name. Follows `cd`
  between repos but leaves hand-set names alone: it only renames when the label is
  numeric (the default) or equals the name it set last (remembered in
  `$TMPDIR/herdr-autotab-<tab id>`).
- `_herdr_report_repobranch` (precmd hook): reports `repobranch=<repo>:<branch>` as
  workspace metadata (`--source zsh-repobranch`) for the spaces rows. Shared by every
  pane in the workspace; the most recent prompt wins. Cleared outside a git repo.

## Feature parity with the tmux sidebar

| tmux-orchestra | herdr |
|---|---|
| `∅ cleared` / `∅ empty session` | `$session` token |
| Last prompt `❯ …` | `$prompt` token |
| Finish age (`now`, `5m` …) | `$age` token plus ticker |
| background / compacting / error states | `$state` token (text only; herdr's own agent status does not know them) |
| Spinners | not possible, herdr uses static glyphs |
| Keyboard selection, orphaned and resumable sessions, unread dots | not ported |

## History and known gaps

- Built incrementally in one session: compared the two sidebars, then added (in order)
  `$session`, `$prompt`, compacting and background state, error state (StopFailure),
  dropped the `idle` label, then finish age. Skipped herdr's separate agents view.
- A one-off `age=now` baseline was written to agents that already existed when the age
  feature landed.
- An early bug showed `∅ cleared` on panes that were not cleared; the prompt hook now
  clears `session`, so it should disappear on the first prompt. Verify if it recurs.
- Backups of earlier configs: `~/.config/herdr/config.toml.bak-herdr*`.
- Reload with `herdr server reload-config` or `prefix+shift+r`.
