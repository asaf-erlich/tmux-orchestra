# Renderer: `bin/orchestra-render` + `lib/render.sh`
## tmux-orchestra v0.1.0

*Part of the [implementation spec](implementation-spec.md). Glyph tables and color defaults are in [core.md](core.md).*

## Loop

```
while true; do
    redraw
    # Wait up to 125 ms, but wake on SIGUSR1 (from set-hooks)
    sleep_interruptible 0.125
done
```

`sleep_interruptible`: SIGUSR1 sets a flag and run `sleep 0.125 &; wait $!` — the signal cancels the wait, and a signal that arrived during `redraw` skips the next sleep entirely.

Process creation is slow on some hosts (endpoint security scans every exec), so a tick costs exactly two execs: one `tmux` and one `awk`.

## Data read (one tmux call per tick)

```sh
tmux display-message -p -t "$TMUX_PANE" '#{pane_width}|#{@orchestra_nerd_fonts}|#{@orchestra_wait_color}' \; \
    list-windows -t "$TMUX_PANE" -F '#{session_name}|#{window_id}|#{window_name}|#{window_active}|#{@ab_agent_state}|#{@ab_current_action}|#{@ab_branch}|#{@ab_cwd}|#{@ab_last_cmd}|#{@ab_progress}|#{@ab_progress_label}|#{@ab_unread}|#{@ab_last_notification}|#{@ab_status_phase}|#{@ab_status_phase__icon}|#{@ab_status_phase__color}|#{@ab_spinner}|#{@ab_selected_window}|#{&&:#{window_active},#{==:#{pane_id},#{@ab_sidebar_pane_id}}}'
```

The first line is the sidebar pane's own width (not `tput cols`, which reports 80 inside `$(...)`) and the two global options; formats resolve global user options. The last two fields of each window line carry the keyboard selection and whether the sidebar has focus (see [sidebar.md](sidebar.md) **Keyboard selection**). `redraw` pipes the whole dump to `render_frame`, which reduces those fields to one selected window id and renders every block in a single awk process. `render_rows WIDTH FRAME NERD WAIT_COLOR [SELECTED]` renders window lines alone (the fixture tests use it) and ignores any fields after `spinner`.

For v0.1 only one status pill is rendered — `phase`. Iterating over arbitrary `@ab_status_*` keys requires a second tmux call per window and is deferred to v0.2.

## Per-window row format

```
┌─ <window_name> ────────────────
│ <state_glyph> <activity_line>
│ <phase_pill>  <progress_bar>  <unread_dot>
└─
```

Where:

- `activity_line = @ab_current_action` if state ∈ {running, waiting}; else `"$ @ab_last_cmd"` if set; else `@ab_cwd`.
- `state_glyph` rotates through a 4-frame animation per tick for running (`⠋⠙⠹⠸`), waiting (`◐◓◑◒`), done (`✓` static), none (empty).
- `phase_pill` = `<icon> <text>` painted with `@ab_status_phase__color`. Nerd-font icon if terminal supports it (detect via `$TERM` containing `nerd`? — no, just honor user's `@orchestra_nerd_fonts` option, default off).
- `progress_bar` = `█████░░░░░ 42%` when `@ab_progress` set. Width: 10 cells.
- `unread_dot` = red `●` when `@ab_unread == 1`, else empty.

**Active window** gets heavy box-drawing borders and bold title text. Waiting state applies the `@orchestra_wait_color` color to borders and text.

## Flicker-free redraw

Do not use `\033[2J` (erase-screen) before drawing. Instead: move cursor to home (`\033[H`), overwrite the previous frame in place, then emit `\033[J` (erase from cursor to end of screen) to clear any leftover lines if content shrank. This ensures no blank frame is ever displayed between redraws.

## Constraints

- `lib/render.sh` must be pure — no tmux calls inside `render_rows`/`render_frame` or the awk program they run, and no per-window or per-field subprocesses. All tmux I/O happens in the `redraw` function in `bin/orchestra-render` before rendering begins.
- **Mouse support:** clicks on a sidebar window row select that window (see [sidebar.md](sidebar.md) **Mouse bindings**). The renderer itself is not involved in click handling — `bin/orchestra-click` maps click Y-coordinates back to windows based on the fixed 3-lines-per-block row height produced here. **If you change the number of lines the awk `window_block` function emits, update `bin/orchestra-click`.**
- No horizontal scrolling. If a window has a very long `@ab_current_action`, truncate to pane-width minus 4 with trailing `…`.
- **Color output:** ANSI emitted by `color_start` in the awk program (`#rrggbb` as 24-bit, color names as `setaf 0-7`, i.e. `ESC[3Nm`). On `TERM=dumb` or when `NO_COLOR` is set, drop all ANSI.
