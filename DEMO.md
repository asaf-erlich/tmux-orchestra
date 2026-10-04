# Demo script

A step-by-step walkthrough of every tmux-orchestra feature, using real
Claude Code sessions wherever possible. Each step is one prompt, command or
key, followed by what the sidebar should show.

Conventions:

- `prefix` is your tmux prefix key (`Ctrl-b` by default).
- **Prompt:** text you type into a Claude Code session.
- `! command` is Claude Code's shell mode: type it in the Claude prompt and
  the command runs in that Claude window's shell. Hooks keep reporting the
  window, so this is the easiest way to drive the `orchestra` CLI for a
  window the sidebar lists.
- Glyphs are shown as *Nerd Fonts / plain*.

## 0. Setup

1. Load the plugin (TPM or `run-shell .../orchestra.tmux` in
   `~/.tmux.conf`) and install the Claude Code hooks from
   [hooks/claude-code/settings.json](hooks/claude-code/settings.json),
   including `StopFailure`, `PreCompact` and `PostCompact`.
2. Turn on Nerd Font glyphs (optional, but the demo looks better):

   ```sh
   tmux set -g @orchestra_nerd_fonts on
   ```

3. Open the sidebar: `prefix + B`. If it was already open from before an
   upgrade, press `prefix + B` twice: a running sidebar keeps the code it
   started with.
4. Start Claude in **default permission mode**, so permission prompts
   actually appear (auto and bypass modes skip them):

   ```sh
   claude --permission-mode default
   ```

   The window shows up in the sidebar as soon as Claude starts.

## 1. Agent states and colors

Run these in order in one Claude window. Keep the sidebar visible.

| Step | Do this | Sidebar shows |
|---|---|---|
| Empty session | Start a fresh `claude` (step 0.4) | dim grey `∅ empty session` |
| Working | **Prompt:** `Read README.md and summarize it in three bullets.` | orange spinner (`✻` / `*`) with `Read: …README.md`, the prompt `❯ Read README.md…` on the bottom row, no age |
| Blocked on you | **Prompt:** `Use Bash to run: touch /tmp/orchestra-demo` | red title and rows, `◐` / `?`, `allow? Bash: …`. Answer the prompt (say no) and it goes back to orange, then idle |
| Idle, seen | Wait for the reply to finish | plain rows, `❯ <your prompt>`, `now` in the top border, which later becomes `1m`, `5m`, ... |
| Idle reminder | Wait a minute after a turn ends | stays plain: Claude's "waiting for your input" reminder no longer marks the window red |
| Waiting on background work | **Prompt:** `Run "sleep 60" with Bash using run_in_background, then end your turn right away without waiting for it.` | blue `◴` / `&` with `1 background: …` for about a minute. When the sleep ends Claude picks the turn back up (orange), then goes idle |
| Background agent | **Prompt:** `Start a background agent that runs "sleep 45" and reports back, then end your turn without waiting.` | blue again, naming the agent's task |
| Finished, not yet seen | **Prompt:** `Run "sleep 20" with Bash, then say done.` Immediately switch to another window (`prefix + n`) | when it finishes: green check `✓` and green rows, the unread dot (`●` / `!`) in the top border. Switching back to the window clears the dot and the green |
| Compacting | Type `/compact` | purple `◜` / `=` with `compacting (manual)`, then idle. Automatic compaction mid-turn shows `compacting (auto)` and goes back to orange |
| Error | A real API error (rate limit, overload) is hard to trigger on demand, so simulate one: `! printf '{"error":"rate_limit"}' \| orchestra-claude-hook stop-failure` | yellow title and rows, `✗` / `X`, `error: rate_limit`, and the unread dot if you are in another window. The next prompt clears it |
| Cleared | Type `/clear` | dim grey `∅ cleared` |

### Changing the colors

The colors are tmux options and the sidebar picks up changes on its next
redraw. While a window is in the blue background state:

```sh
tmux set -g @orchestra_background_color magenta
tmux set -gu @orchestra_background_color   # back to the default
```

The others: `@orchestra_wait_color`, `@orchestra_compacting_color`,
`@orchestra_error_color`, `@orchestra_done_color`. Running windows always use
their spinner's color (Claude orange).

## 2. Sidebar and navigation

| Step | Do this | Sidebar shows |
|---|---|---|
| Only Claude windows | `prefix + c` to open a plain shell window | the shell window is not listed. With no Claude windows anywhere, the sidebar says `no claude sessions` |
| Follows focus | Switch windows (`prefix + n` / `prefix + p`) | the sidebar pane moves into whichever window you focus; the focused window has a heavy border |
| One sidebar per server | `tmux new-session -d -s demo2`, then `tmux switch-client -t demo2` and run `claude` there | windows from both sessions, titled `session:window`; the sidebar follows you into `demo2` |
| Switch from the sidebar | Click a window in another session | your client switches to that session and window |
| Keyboard selection | Click the sidebar (or `prefix` + arrow keys to it), then press Up/Down or `j`/`k`, or scroll the mouse wheel | a `▌` bar and reverse-video title on the selected window, without switching yet |
| Open the selection | `Enter` | switches to the selected window |
| Width | `tmux set -gu @orchestra_sidebar_width; tmux set -g @orchestra_width 48`, then `prefix + B` twice | the sidebar reopens 48 columns wide. Dragging the sidebar's edge also sticks: the last width is remembered in `@orchestra_sidebar_width`, which wins over `@orchestra_width` |

## 3. Background Claude sessions

Sessions run by the Claude Code daemon have no tmux pane, but the sidebar
lists them under a `── background ──` separator.

| Step | Do this | Sidebar shows |
|---|---|---|
| Start one | In any shell: `claude --bg "Count from 1 to 30, running sleep 2 between numbers with Bash"` | within about 10 seconds a block below `── background ──` with the session's name, state and directory |
| Attach | Select it (keyboard or click) and press `Enter` | a new window in its directory running `claude attach <id>`; while that window is open the session is listed as a normal window |
| Detach | Leave the attached session | the window closes and the session goes back under the separator |
| Hide the list | `tmux set -g @orchestra_background off`, then `prefix + B` twice | no background section. `tmux set -gu @orchestra_background` and reopen to bring it back |

The refresh period is `@orchestra_bg_interval` seconds (default 10).

## 4. The orchestra CLI

Run these from a Claude window with `!`, so the sidebar shows the result on
that window.

| Step | Do this | Sidebar shows |
|---|---|---|
| Status pill | `! orchestra set-status phase build --icon '*'` | `* build` on the bottom row |
| Progress bar | `! orchestra set-progress 0.42 --label Tests` | `████░░░░░░ 42% Tests` (`####------` without Nerd Fonts) |
| Clear them | `! orchestra clear-status phase` and `! orchestra clear-progress` | the bottom row goes back to the prompt or directory |
| Notification | `! orchestra notify --title Build --body done`, then switch away and back | a desktop notification, and the unread dot until you return. `--quiet` skips the desktop notification |
| Set a state by hand | `! orchestra set-state background --action 'waiting on CI'` | blue background state. `! orchestra clear-state` resets it |
| Last prompt | `! orchestra set-prompt 'fix the flaky test'` | `❯ fix the flaky test` |

If `orchestra` is not found, the pane was opened before the plugin loaded
and has the old `PATH`; open a new pane, or use the full path to the
plugin's `bin/` directory.

## 5. Catching up sessions started before the hooks

For Claude sessions that were already running when you installed the hooks:

```sh
orchestra-claude-hook backfill
```

It fills in each window's last prompt, finish time and empty-session marker
from Claude's session files, and prints one line per window it updated.
