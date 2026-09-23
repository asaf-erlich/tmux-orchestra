# Sidebar keyboard selection and click mapping, shared by bin/orchestra-select,
# bin/orchestra-click and the key reader in bin/orchestra-render (which
# sources this once, so a keypress costs no shell startup). Only shell
# builtins besides the tmux calls: process creation is slow on some systems.
#
# The sidebar lists only windows running Claude Code, in window order. This
# file owns that filter: ORCHESTRA_CLAUDE_PANE is the per-pane tmux format
# the renderer also appends to its list-panes dump, and select_windows builds
# the same filtered, ordered list for keyboard selection and clicks.
#
# The selection is stored as a window_id in the session option
# @ab_selected_window so it survives window reordering. An unset or stale
# value means "the active window", or the first listed window when the
# active window is not listed.

# tmux format: 1 when the pane runs Claude Code, else 0. The Claude Code
# binary is named after its version (~/.local/share/claude/versions/X.Y.Z),
# so pane_current_command is e.g. "2.1.280"; "claude" covers other installs.
# The sidebar pane runs sh, so it never matches.
# shellcheck disable=SC2034 # Read by bin/orchestra-render and the tests.
ORCHESTRA_CLAUDE_PANE='#{m/r:^(claude|[0-9]+\.[0-9]+\.[0-9]+)$,#{pane_current_command}}'

# Usage: select_windows SESSION
# One tmux call. Sets _sel_windows to one "window_id|window_active|stored"
# line per listed (Claude) window, in window order, and SELECT_SIDEBAR_PID to
# the session's @ab_sidebar_pid. Returns 1 if the session cannot be listed.
select_windows() {
	_sel_panes=$(tmux list-panes -s -t "$1" -F "#{window_id}|#{window_active}|#{@ab_sidebar_pid}|#{@ab_selected_window}|$ORCHESTRA_CLAUDE_PANE" 2>/dev/null) || return 1
	[ -n "$_sel_panes" ] || return 1
	_sel_windows=''
	_sel_last=''
	SELECT_SIDEBAR_PID=''
	# Panes of one window are consecutive, so a window is kept once, on its
	# first Claude pane.
	while IFS="|" read -r _sel_id _sel_act _sel_pid _sel_stored _sel_claude; do
		SELECT_SIDEBAR_PID=$_sel_pid
		[ "$_sel_claude" = '1' ] || continue
		[ "$_sel_id" != "$_sel_last" ] || continue
		_sel_last=$_sel_id
		_sel_windows="$_sel_windows$_sel_id|$_sel_act|$_sel_stored
"
	done <<EOF
$_sel_panes
EOF
}

# Usage: select_pick N
# Sets _sel_pick to the window id at 1-based position N of _sel_windows, or
# empty if out of range.
select_pick() {
	_sel_i=0
	_sel_pick=''
	while IFS="|" read -r _sel_id _sel_rest; do
		[ -n "$_sel_id" ] || continue
		_sel_i=$((_sel_i + 1))
		if [ "$_sel_i" -eq "$1" ]; then
			_sel_pick=$_sel_id
			return 0
		fi
	done <<EOF
$_sel_windows
EOF
}

# Usage: select_move SESSION DELTA [enter]
# Moves the selection DELTA listed windows down (negative: up), clamped at
# both ends. With "enter", clears the selection and runs select-window on the
# result instead of storing it. Two tmux calls. Sets SELECT_SIDEBAR_PID to
# the session's @ab_sidebar_pid. Returns 1 if the session's windows cannot
# be listed.
# shellcheck disable=SC2034 # SELECT_SIDEBAR_PID is read by the caller.
select_move() {
	_sel_session=$1
	_sel_delta=$2
	_sel_enter=${3:-}

	select_windows "$_sel_session" || return 1
	[ -n "$_sel_windows" ] || return 0

	# Count windows and find the selected and active positions.
	_sel_n=0
	_sel_cur=0
	_sel_active=0
	while IFS="|" read -r _sel_id _sel_act _sel_stored; do
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
		tmux set-option -qu -t "$_sel_session" @ab_selected_window \; select-window -t "$_sel_pick" >/dev/null 2>&1 || true
	else
		tmux set-option -q -t "$_sel_session" @ab_selected_window "$_sel_pick" >/dev/null 2>&1 || true
	fi
}

# Usage: select_row SESSION ROW
# Runs select-window on the listed window at 0-based sidebar block ROW (a
# click). Out of range is a no-op. Two tmux calls.
select_row() {
	select_windows "$1" || return 0
	select_pick $(($2 + 1))
	[ -n "$_sel_pick" ] || return 0
	tmux select-window -t "$_sel_pick" >/dev/null 2>&1 || true
}

# Usage: select_reset SESSION
# Clears the selection. One tmux call; sets SELECT_SIDEBAR_PID.
# shellcheck disable=SC2034
select_reset() {
	SELECT_SIDEBAR_PID=$(tmux set-option -qu -t "$1" @ab_selected_window \; show-options -qv -t "$1" @ab_sidebar_pid 2>/dev/null) || SELECT_SIDEBAR_PID=''
}
