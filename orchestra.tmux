#!/bin/sh
set -eu

# Resolve the plugin root the same way TPM plugins commonly do so the plugin
# works no matter how tmux sources this file.
CURRENT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

tmux set-option -gq focus-events on
tmux set-option -gq mouse on
# Defaults only: a value set in tmux.conf before this file runs wins.
set_default() {
    [ -n "$(tmux show-option -gqv "$1")" ] || tmux set-option -gq "$1" "$2"
}
set_default @orchestra_nerd_fonts off
set_default @orchestra_wait_color '#d29922'
set_default @orchestra_bg_interval 10
set_default @orchestra_key B
set_default @orchestra_width 32

tmux set-option -ga update-environment 'ORCHESTRA'
tmux set-option -ga update-environment 'ORCHESTRA_WINDOW_ID'
tmux set-option -ga update-environment 'ORCHESTRA_PANE_ID'

tmux set-environment -g ORCHESTRA 1
tmux set-environment -g ORCHESTRA_PLUGIN_DIR "$CURRENT_DIR"
tmux set-environment -g PATH "$CURRENT_DIR/bin:$PATH"

key=$(tmux show-option -gvq @orchestra_key)
[ -n "$key" ] || key=B
tmux bind-key "$key" run-shell "$CURRENT_DIR/bin/orchestra-toggle"

# There is one sidebar per server; its pane id, renderer pid, width and
# keyboard selection are global options (@orchestra_sidebar_pane_id,
# @orchestra_sidebar_pid, @orchestra_sidebar_width,
# @orchestra_selected_window). Earlier versions kept one sidebar per session
# in session options (@ab_sidebar_pane_id, @ab_sidebar_pid, @ab_width,
# @ab_selected_window): close those sidebars and drop the options, so no
# orphaned renderer is left that the toggle key can no longer reach.
tmux list-sessions -F '#{session_id}|#{@ab_sidebar_pane_id}|#{@ab_sidebar_pid}#{@ab_width}#{@ab_selected_window}' 2>/dev/null | while IFS='|' read -r old_session old_pane old_rest; do
    [ -n "$old_session" ] || continue
    [ -n "$old_pane$old_rest" ] || continue
    if [ -n "$old_pane" ]; then
        tmux kill-pane -t "$old_pane" >/dev/null 2>&1 || true
    fi
    tmux set-option -qu -t "$old_session" @ab_sidebar_pane_id \; \
        set-option -qu -t "$old_session" @ab_sidebar_pid \; \
        set-option -qu -t "$old_session" @ab_width \; \
        set-option -qu -t "$old_session" @ab_selected_window >/dev/null 2>&1 || true
done

# shellcheck disable=SC2016
notify_renderer='pid=$(tmux show-option -gvq @orchestra_sidebar_pid); [ -n "$pid" ] && kill -USR1 "$pid" 2>/dev/null || true'

# Keep discovery env vars fresh and clear unread state when the user returns to
# a window. Any focus change also drops the sidebar's keyboard selection, so it
# starts on the active window each time the sidebar gains focus. The hook also
# nudges the renderer so both changes show immediately instead of waiting for
# the next poll tick, and moves the sidebar into the focused window, whatever
# its session.
tmux set-hook -g pane-focus-in "run-shell 'tmux set-option -wq -t \"#{window_id}\" @ab_unread \"\" >/dev/null 2>&1 || true; tmux set-option -gqu @orchestra_selected_window >/dev/null 2>&1 || true; tmux set-environment -t \"#{session_name}\" ORCHESTRA_WINDOW_ID \"#{window_id}\"; tmux set-environment -t \"#{session_name}\" ORCHESTRA_PANE_ID \"#{pane_id}\"; $notify_renderer; \"$CURRENT_DIR/bin/orchestra-follow\" \"#{window_id}\" \"#{pane_id}\"'"
tmux set-hook -g window-renamed "run-shell '$notify_renderer'"
# A client switching sessions (switch-client from the sidebar, byobu's session
# keys, choose-tree) brings the sidebar to the new session's active pane. The
# hook's formats resolve against the client, so they name the window it now
# shows.
tmux set-hook -g client-session-changed "run-shell '$notify_renderer; \"$CURRENT_DIR/bin/orchestra-follow\" \"#{window_id}\" \"#{pane_id}\"'"
# shellcheck disable=SC1083,SC2154
tmux set-hook -g after-resize-pane "run-shell 'sidebar=\$(tmux show-option -gvq @orchestra_sidebar_pane_id); [ -n \"\$sidebar\" ] && [ \"\$sidebar\" = \"#{pane_id}\" ] && tmux set-option -gq @orchestra_sidebar_width \"#{pane_width}\" >/dev/null 2>&1 || true'"

# Mouse: clicking a window row in the sidebar switches to that window.
# Non-sidebar clicks fall through to the default select-pane behaviour.
# shellcheck disable=SC2016
tmux bind-key -n MouseDown1Pane \
    "if-shell -F -t = '#{==:#{pane_id},#{@orchestra_sidebar_pane_id}}' \
        \"run-shell '$CURRENT_DIR/bin/orchestra-click #{mouse_y} #{session_name}'\" \
        'select-pane -t=; send-keys -M'"
