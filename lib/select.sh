# Sidebar keyboard selection and click mapping, shared by bin/orchestra-select,
# bin/orchestra-click and the key reader in bin/orchestra-render (which
# sources this once, so a keypress costs no shell startup). Only shell
# builtins besides the tmux calls: process creation is slow on some systems.
#
# The sidebar lists the windows running Claude Code in every session of the
# server, in session-name then window-index order (list-panes -a order). This
# file owns that filter: ORCHESTRA_CLAUDE_PANE is the per-pane tmux format
# the renderer also appends to its list-panes dump, and select_windows builds
# the same filtered, ordered list for keyboard selection and clicks.
#
# There is one sidebar per server. Its state lives in global options:
# @orchestra_sidebar_pane_id, @orchestra_sidebar_pid, @orchestra_sidebar_width
# and @orchestra_selected_window. The selection is a window_id, so it
# survives window reordering. An unset or stale value means "the active
# window of the viewing session", or the first listed window when that
# window is not listed.

# tmux format: 1 when the pane runs Claude Code, else 0. The Claude Code
# binary is named after its version (~/.local/share/claude/versions/X.Y.Z),
# so pane_current_command is e.g. "2.1.280"; "claude" covers other installs.
# The sidebar pane runs sh, so it never matches.
# shellcheck disable=SC2034 # Read by bin/orchestra-render and the tests.
ORCHESTRA_CLAUDE_PANE='#{m/r:^(claude|[0-9]+\.[0-9]+\.[0-9]+)$,#{pane_current_command}}'

# Usage: select_windows TARGET
# TARGET (a session, or a pane such as the sidebar's $TMUX_PANE) names the
# viewing session: its active window is "active", and its most recently
# active client is the one Enter and clicks switch. One tmux call. Sets:
#   _sel_windows        one "window_id|active|session_id" line per listed
#                       (Claude) window, in sidebar order
#   _sel_stored         @orchestra_selected_window
#   _sel_view_session   the viewing session's id
#   _sel_client         the client to switch, or empty if none is attached
#   SELECT_SIDEBAR_PID  @orchestra_sidebar_pid
# Returns 1 if TARGET cannot be resolved.
select_windows() {
	_sel_out=$(tmux display-message -p -t "$1" '#{session_id}|#{@orchestra_sidebar_pid}|#{@orchestra_selected_window}' \; \
		list-panes -a -F "#{window_id}|#{window_active}|$ORCHESTRA_CLAUDE_PANE|#{session_id}" \; \
		list-clients -t "$1" -F '>#{client_activity}|#{client_name}' 2>/dev/null) || return 1
	[ -n "$_sel_out" ] || return 1
	_sel_windows=''
	_sel_last=''
	_sel_stored=''
	_sel_client=''
	_sel_client_act=-1
	_sel_view_session=''
	SELECT_SIDEBAR_PID=''
	# The header line (session ids start with $), then pane lines (window ids
	# start with @), then client lines (prefixed >). Panes of one window are
	# consecutive, so a window is kept once, on its first Claude pane; a
	# window linked into several sessions is listed under the first.
	while IFS="|" read -r _sel_a _sel_b _sel_c _sel_d; do
		case "$_sel_a" in
			@*)
				[ "$_sel_c" = '1' ] || continue
				[ "$_sel_a" != "$_sel_last" ] || continue
				_sel_last=$_sel_a
				# window_active is per session; only the viewing session's
				# active window is the one the client shows.
				[ "$_sel_d" = "$_sel_view_session" ] || _sel_b=0
				_sel_windows="$_sel_windows$_sel_a|$_sel_b|$_sel_d
"
				;;
			'>'*)
				_sel_a=${_sel_a#>}
				case "$_sel_a" in '' | *[!0-9]*) _sel_a=0 ;; esac
				if [ "$_sel_a" -gt "$_sel_client_act" ]; then
					_sel_client_act=$_sel_a
					_sel_client=$_sel_b
				fi
				;;
			*)
				[ -z "$_sel_view_session" ] || continue
				_sel_view_session=$_sel_a
				SELECT_SIDEBAR_PID=$_sel_b
				_sel_stored=$_sel_c
				;;
		esac
	done <<EOF
$_sel_out
EOF
	[ -n "$_sel_view_session" ] || return 1
}

# Usage: select_pick N
# Sets _sel_pick (and _sel_pick_session) to the window id (and its session
# id) at 1-based position N of _sel_windows, or empty if out of range.
select_pick() {
	_sel_i=0
	_sel_pick=''
	_sel_pick_session=''
	while IFS="|" read -r _sel_id _sel_act _sel_sess; do
		[ -n "$_sel_id" ] || continue
		_sel_i=$((_sel_i + 1))
		if [ "$_sel_i" -eq "$1" ]; then
			_sel_pick=$_sel_id
			_sel_pick_session=$_sel_sess
			return 0
		fi
	done <<EOF
$_sel_windows
EOF
}

# Usage: select_go
# Clears the selection and shows _sel_pick on the viewing client. One tmux
# call. A window in the viewing session is selected; for a window in another
# session the viewing client (_sel_client, always named: from run-shell or a
# background process the "current client" is ambiguous) is switched to it.
# The client-session-changed and pane-focus-in hooks then move the sidebar.
select_go() {
	if [ "$_sel_pick_session" = "$_sel_view_session" ] || [ -z "$_sel_client" ]; then
		tmux set-option -gqu @orchestra_selected_window \; select-window -t "$_sel_pick" >/dev/null 2>&1 || true
	else
		tmux set-option -gqu @orchestra_selected_window \; \
			switch-client -c "$_sel_client" -t "$_sel_pick" \; \
			select-window -t "$_sel_pick" >/dev/null 2>&1 || true
	fi
}

# Usage: select_move TARGET DELTA [enter]
# Moves the selection DELTA listed windows down (negative: up), clamped at
# both ends. With "enter", clears the selection and shows the result instead
# of storing it (select_go). Two tmux calls. TARGET is as for select_windows.
# Sets SELECT_SIDEBAR_PID. Returns 1 if TARGET cannot be resolved.
select_move() {
	_sel_delta=$2
	_sel_enter=${3:-}

	select_windows "$1" || return 1
	[ -n "$_sel_windows" ] || return 0

	# Count windows and find the selected and active positions.
	_sel_n=0
	_sel_cur=0
	_sel_active=0
	while IFS="|" read -r _sel_id _sel_act _sel_sess; do
		[ -n "$_sel_id" ] || continue
		_sel_n=$((_sel_n + 1))
		[ "$_sel_act" = '1' ] && _sel_active=$_sel_n
		[ -n "$_sel_stored" ] && [ "$_sel_id" = "$_sel_stored" ] && _sel_cur=$_sel_n
	done <<EOF
$_sel_windows
EOF
	# Unset or stale: the active window, or the first listed window when the
	# active window is not listed.
	[ "$_sel_cur" -gt 0 ] || _sel_cur=$_sel_active
	[ "$_sel_cur" -gt 0 ] || _sel_cur=1
	_sel_cur=$((_sel_cur + _sel_delta))
	[ "$_sel_cur" -ge 1 ] || _sel_cur=1
	[ "$_sel_cur" -le "$_sel_n" ] || _sel_cur=$_sel_n

	select_pick "$_sel_cur"
	[ -n "$_sel_pick" ] || return 0

	if [ -n "$_sel_enter" ]; then
		select_go
	else
		tmux set-option -gq @orchestra_selected_window "$_sel_pick" >/dev/null 2>&1 || true
	fi
}

# Usage: select_row TARGET ROW
# Shows the listed window at 0-based sidebar block ROW (a click), as Enter
# does. Out of range is a no-op. Two tmux calls.
select_row() {
	select_windows "$1" || return 0
	select_pick $(($2 + 1))
	[ -n "$_sel_pick" ] || return 0
	select_go
}

# Usage: select_reset
# Clears the selection. One tmux call; sets SELECT_SIDEBAR_PID.
# shellcheck disable=SC2034 # SELECT_SIDEBAR_PID is read by the caller.
select_reset() {
	SELECT_SIDEBAR_PID=$(tmux set-option -gqu @orchestra_selected_window \; show-options -gqv @orchestra_sidebar_pid 2>/dev/null) || SELECT_SIDEBAR_PID=''
}
