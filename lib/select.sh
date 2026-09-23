# Sidebar keyboard selection, shared by bin/orchestra-select and the key
# reader in bin/orchestra-render (which sources this once, so a keypress
# costs no shell startup). Only shell builtins besides the tmux calls:
# process creation is slow on some systems.
#
# The selection is stored as a window_id in the session option
# @ab_selected_window so it survives window reordering. An unset or stale
# value means "the active window".

# Usage: select_move SESSION DELTA [enter]
# Moves the selection DELTA windows down (negative: up), clamped at both
# ends. With "enter", clears the selection and runs select-window on the
# result instead of storing it. Two tmux calls. Sets SELECT_SIDEBAR_PID to
# the session's @ab_sidebar_pid. Returns 1 if the session's windows cannot
# be listed.
# shellcheck disable=SC2034 # SELECT_SIDEBAR_PID is read by the caller.
select_move() {
	_sel_session=$1
	_sel_delta=$2
	_sel_enter=${3:-}

	_sel_windows=$(tmux list-windows -t "$_sel_session" -F '#{window_id}|#{window_active}|#{@ab_sidebar_pid}|#{@ab_selected_window}' 2>/dev/null) || return 1
	[ -n "$_sel_windows" ] || return 1

	# Pass 1: count windows and find the selected and active positions.
	_sel_n=0
	_sel_cur=0
	_sel_active=0
	SELECT_SIDEBAR_PID=''
	while IFS="|" read -r _sel_id _sel_act _sel_pid _sel_stored; do
		_sel_n=$((_sel_n + 1))
		[ "$_sel_act" = '1' ] && _sel_active=$_sel_n
		[ -n "$_sel_stored" ] && [ "$_sel_id" = "$_sel_stored" ] && _sel_cur=$_sel_n
		SELECT_SIDEBAR_PID=$_sel_pid
	done <<EOF
$_sel_windows
EOF
	[ "$_sel_cur" -gt 0 ] || _sel_cur=$_sel_active
	[ "$_sel_cur" -gt 0 ] || _sel_cur=1
	_sel_cur=$((_sel_cur + _sel_delta))
	[ "$_sel_cur" -ge 1 ] || _sel_cur=1
	[ "$_sel_cur" -le "$_sel_n" ] || _sel_cur=$_sel_n

	# Pass 2: the window id at that position.
	_sel_i=0
	_sel_pick=''
	while IFS="|" read -r _sel_id _sel_rest; do
		_sel_i=$((_sel_i + 1))
		if [ "$_sel_i" -eq "$_sel_cur" ]; then
			_sel_pick=$_sel_id
			break
		fi
	done <<EOF
$_sel_windows
EOF
	[ -n "$_sel_pick" ] || return 0

	if [ -n "$_sel_enter" ]; then
		tmux set-option -qu -t "$_sel_session" @ab_selected_window \; select-window -t "$_sel_pick" >/dev/null 2>&1 || true
	else
		tmux set-option -q -t "$_sel_session" @ab_selected_window "$_sel_pick" >/dev/null 2>&1 || true
	fi
}

# Usage: select_reset SESSION
# Clears the selection. One tmux call; sets SELECT_SIDEBAR_PID.
# shellcheck disable=SC2034
select_reset() {
	SELECT_SIDEBAR_PID=$(tmux set-option -qu -t "$1" @ab_selected_window \; show-options -qv -t "$1" @ab_sidebar_pid 2>/dev/null) || SELECT_SIDEBAR_PID=''
}
