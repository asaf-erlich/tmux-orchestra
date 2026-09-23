# Sidebar: Toggle & TPM Entrypoint
## tmux-orchestra v0.1.0

*Part of the [implementation spec](implementation-spec.md). See [core.md](core.md) for the global sidebar options (`@orchestra_sidebar_pane_id`, `@orchestra_sidebar_pid`, `@orchestra_sidebar_width`, `@orchestra_selected_window`).*

There is one sidebar per tmux server. It lists the Claude windows of every session and follows focus across windows and sessions, so its state lives in global options (`set-option -g`), not session options.

## Sidebar toggle (`bin/orchestra-toggle`)

Behavior:

1. Read global option `@orchestra_sidebar_pane_id`.
2. If set and the pane still exists (in any session) → `tmux kill-pane` it, unset `@orchestra_sidebar_pane_id` and `@orchestra_sidebar_pid`, return.
3. Else: read cached width from `@orchestra_sidebar_width` (fallback `@orchestra_width`, default 32). `tmux split-window -bhd -l "$width" -t "$current_window" -c "$PWD" orchestra-render`. Store the new pane id, renderer pid and width in the global options.

## Window-following (`bin/orchestra-follow`)

The sidebar pane is not fixed to a single window or session. On every `pane-focus-in`, and on `client-session-changed` (whose formats name the window and pane the client now shows), `orchestra-follow WINDOW_ID PANE_ID` checks whether that window already contains the sidebar pane. If the pane in `@orchestra_sidebar_pane_id` no longer exists, it unsets `@orchestra_sidebar_pane_id` / `@orchestra_sidebar_pid` and exits. If the sidebar is elsewhere, it runs:

```
tmux move-pane -hb -l <width> -s <sidebar_pane> -t <active_pane_in_current_window>
```

This transplants the pane (and its running `orchestra-render` process) into the new window's layout on the left edge, across sessions if needed. Because the same process moves with the pane, there is no restart flicker. Focus-loop protections: the hooks pass explicit window and pane ids, an already-here check exits early, and `select-pane` runs only when the target pane is not already active.

**Several clients.** With clients attached to different sessions, the one sidebar follows the most recent focus change, so it can only be visible in one of them.

**Window-closing edge case.** If the source window contained only the sidebar pane, `move-pane` leaves it empty and tmux closes that window. This is acceptable behaviour — the user was already leaving that window by switching focus elsewhere.

## `orchestra.tmux` (TPM entrypoint)

Must:

- Set default options (`focus-events on`, `mouse on`, `@orchestra_nerd_fonts off`, `@orchestra_wait_color '#d29922'`, `@orchestra_key B`, `@orchestra_width 32`). `focus-events` is required for `pane-focus-in` to fire on window/pane switches. `mouse on` is required for the sidebar click binding below.
- Bind `prefix + <key>` (from option) to `run-shell "$CURRENT_DIR/bin/orchestra-toggle"`.
- Register `pane-focus-in` hook: clear `@ab_unread`, write `ORCHESTRA_WINDOW_ID` / `ORCHESTRA_PANE_ID`, `kill -USR1` the renderer, and run `orchestra-follow` to move the sidebar pane to the current window if needed.
- Register `window-renamed` hook: `kill -USR1` the renderer process (PID from the global `@orchestra_sidebar_pid`).
- Register `client-session-changed` hook: `kill -USR1` the renderer and run `orchestra-follow "#{window_id}" "#{pane_id}"`, so the sidebar moves into the session the client switched to.
- Register `after-resize-pane` hook: if the resized pane is the sidebar (`pane_id == @orchestra_sidebar_pane_id`), persist the new width into the global `@orchestra_sidebar_width` so the next `orchestra-toggle` restores the user-resized width.
- Migrate from per-session sidebars: for every session with `@ab_sidebar_pane_id` / `@ab_sidebar_pid` / `@ab_width` / `@ab_selected_window` set, kill that old sidebar pane and unset the options (one tmux call per affected session; none on a clean server).
- Bind `MouseDown1Pane` globally (see **Mouse bindings** below).
- Prepend `$CURRENT_DIR/bin` to `PATH` in the session env so `orchestra` is callable from any pane.

Follow the TPM convention for `$CURRENT_DIR` resolution (copy from `tmux-sidebar`'s `sidebar.tmux`).

## Mouse bindings

The sidebar is click-navigable: clicking on a window block in the sidebar selects that window. Non-sidebar clicks fall through to tmux's default `select-pane` + `send-keys -M` behaviour (so mouse support in application panes is unchanged).

Implementation:

```tmux
bind-key -n MouseDown1Pane \
    if-shell -F -t = '#{==:#{pane_id},#{@orchestra_sidebar_pane_id}}' \
        "run-shell '$CURRENT_DIR/bin/orchestra-click #{mouse_y} #{session_name}'" \
        'select-pane -t=; send-keys -M'
```

`bin/orchestra-click` maps a Y coordinate to a window block and shows that window: `select-window` for a window in the sidebar's session, or `switch-client -c <client> -t <window_id>` (then `select-window`) for one in another session, where `<client>` is the most recently active client attached to the sidebar's session (from `list-clients -t`, fetched in the same tmux call as the window list). The client is always named: from `run-shell` or a background process the "current client" is ambiguous. Each window block rendered by `window_block` (awk, in `lib/render.sh`) is exactly 3 lines tall (top border, detail row, meta row), so `block_index = mouse_y / 3`. The sidebar lists only windows running Claude Code (see [renderer.md](renderer.md) **Data read**), so the script picks the Nth entry of the same filtered, ordered list (`select_row` / `select_windows` in `lib/select.sh`, built from `tmux list-panes -a` with the shared `ORCHESTRA_CLAUDE_PANE` flag) — so the click-to-window mapping is tied to the renderer's row height and filter. If `window_block` ever changes its line count, update [bin/orchestra-click](../bin/orchestra-click) to match.

## Keyboard selection

With the sidebar pane focused, Up/Down (also `k`/`j`, and the mouse wheel, which tmux delivers as cursor keys in the alternate screen) move a selection across the window blocks without switching windows; Enter shows it, the same effect as a click (including `switch-client` to another session). No root-table bindings are involved: `orchestra-render` puts the tty in `-icanon -echo min 1 time 0` and starts a background reader that blocks in `dd` on the pane's stdin (no work while idle), decodes `ESC [ A`/`ESC [ B` (and `ESC O A/B`), `k`, `j`, CR/LF with shell builtins, folds all the keys of one read into a net movement (autorepeat piles keys up while an update runs), and applies it with `select_move` from `lib/select.sh`, which the renderer sources once: two tmux calls per burst (one call reads the viewing session from the sidebar pane `$TMUX_PANE`, the global options, all panes and the session's clients, reduced to the listed Claude windows; then one call sets the option, or clears it and shows the window for Enter), then SIGUSR1 to the renderer. Selection walks the global list, across sessions. The viewing session is resolved on every burst, since the sidebar pane moves between sessions. The reader is killed and the tty restored in the renderer's EXIT trap.

`bin/orchestra-select <up|down|enter|reset> <session>` is the same logic as a command, with `<session>` as the viewing session. The selection is stored as a window_id in the global option `@orchestra_selected_window` (so it survives reordering), clamps at both ends, and sends SIGUSR1 to the renderer. An unset or stale value means the viewing session's active window, or the first listed window when that window is not a Claude window (other sessions' active windows do not count). Enter and every `pane-focus-in` clear it, so the selection starts on the active window whenever the sidebar gains focus.

The renderer shows the selection while the sidebar has focus, and when unfocused only if it points away from the active window (wheel scrolling). A selected block has `▌` as the left edge of all three lines and a reverse-video title, distinct from the heavy-bordered active window.
