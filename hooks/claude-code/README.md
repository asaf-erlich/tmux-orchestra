# Claude Code hook template

Merge `settings.json` into `~/.claude/settings.json` to map Claude Code hook
events onto `orchestra` status updates.

`SessionStart` and `SessionEnd` run `orchestra clear-state`, so state left
behind by a Claude that exited or was killed before its `Stop` hook ran does
not reappear when Claude starts again in that window. (The sidebar lists only
windows whose panes are running Claude Code, so a window where Claude is gone
is hidden regardless.)

## Note about jq

The template uses `jq` because Claude Code provides structured JSON hook input.
`tmux-orchestra` itself does **not** depend on `jq`; only this optional hook
template does.
