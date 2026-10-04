# Sidebar keyboard selection and click mapping, shared by bin/orchestra-select,
# bin/orchestra-click and the key reader in bin/orchestra-render (which
# sources this once, so a keypress costs no shell startup). Only shell
# builtins besides the tmux calls: process creation is slow on some systems.
#
# The sidebar lists the panes running Claude Code in every session of the
# server, one row each, in session-name, window-index then pane-index order
# (list-panes -a order). This file owns that filter: ORCHESTRA_CLAUDE_PANE is
# the per-pane tmux format the renderer also appends to its list-panes dump,
# and select_windows builds the same filtered, ordered list for keyboard
# selection and clicks.
#
# There is one sidebar per server. Its state lives in global options:
# @orchestra_sidebar_pane_id, @orchestra_sidebar_pid, @orchestra_sidebar_width
# and @orchestra_selected_window. The selection is a pane_id (or "bg:<id>"),
# so it survives window reordering. An unset or stale value means "the
# active pane of the viewing session's active window" (else its previously
# active pane, else its first Claude pane), or the first listed pane when
# that window is not listed.

# tmux format: 1 when the pane runs Claude Code, else 0. The Claude Code
# binary is named after its version (~/.local/share/claude/versions/X.Y.Z),
# so pane_current_command is e.g. "2.1.280"; "claude" covers other installs.
# The sidebar pane runs sh, so it never matches.
# shellcheck disable=SC2034 # Read by bin/orchestra-render and the tests.
ORCHESTRA_CLAUDE_PANE='#{m/r:^(claude|[0-9]+\.[0-9]+\.[0-9]+)$,#{pane_current_command}}'

# tmux format for select_windows: 0 outside the active window, else 1 for
# its active pane, 2 for its previously active pane and 3 for any other.
ORCHESTRA_PANE_RANK='#{?window_active,#{?pane_active,1,#{?pane_last,2,3}},0}'

# Usage: select_windows TARGET
# TARGET (a session, or a pane such as the sidebar's $TMUX_PANE) names the
# viewing session: the best ranked Claude pane of its active window (see
# ORCHESTRA_PANE_RANK) is "active", and its most recently active client is
# the one Enter and clicks switch. One tmux call. Sets:
#   _sel_windows        one "pane_id|rank|session_id" line per listed
#                       (Claude) pane, in sidebar order (rank 0 outside the
#                       viewing session's active window), then one
#                       "bg:<id>|0|" line per background session
#   _sel_nwin           the number of listed panes (not background sessions)
#   _sel_bg             @orchestra_bg_agents ("id;state;started;cwd;name|...")
#   _sel_stored         @orchestra_selected_window
#   _sel_view_session   the viewing session's id
#   _sel_client         the client to switch, or empty if none is attached
#   SELECT_SIDEBAR_PID  @orchestra_sidebar_pid
# Returns 1 if TARGET cannot be resolved.
select_windows() {
	_sel_out=$(tmux display-message -p -t "$1" '#{session_id}|#{@orchestra_sidebar_pid}|#{@orchestra_selected_window}' \; \
		list-panes -a -F "#{pane_id}|$ORCHESTRA_PANE_RANK|$ORCHESTRA_CLAUDE_PANE|#{session_id}" \; \
		list-clients -t "$1" -F '>#{client_activity}|#{client_name}' \; \
		display-message -p -t "$1" '|bg|#{@orchestra_bg_agents}' 2>/dev/null) || return 1
	[ -n "$_sel_out" ] || return 1
	_sel_windows=''
	_sel_seen=' '
	_sel_stored=''
	_sel_client=''
	_sel_client_act=-1
	_sel_view_session=''
	_sel_nwin=0
	_sel_bg=''
	SELECT_SIDEBAR_PID=''
	# The header line (session ids start with $), then pane lines (pane ids
	# start with %), then client lines (prefixed >). Each Claude pane is kept
	# once; a pane of a window linked into several sessions is listed under
	# the first. The last line, "|bg|...", carries the background sessions
	# (session ids are never empty).
	while IFS="|" read -r _sel_a _sel_b _sel_c _sel_d; do
		case "$_sel_a" in
			%*)
				[ "$_sel_c" = '1' ] || continue
				case "$_sel_seen" in *" $_sel_a "*) continue ;; esac
				_sel_seen="$_sel_seen$_sel_a "
				# window_active is per session; only the viewing session's
				# active window is the one the client shows.
				[ "$_sel_d" = "$_sel_view_session" ] || _sel_b=0
				_sel_windows="$_sel_windows$_sel_a|$_sel_b|$_sel_d
"
				_sel_nwin=$((_sel_nwin + 1))
				;;
			'>'*)
				_sel_a=${_sel_a#>}
				case "$_sel_a" in '' | *[!0-9]*) _sel_a=0 ;; esac
				if [ "$_sel_a" -gt "$_sel_client_act" ]; then
					_sel_client_act=$_sel_a
					_sel_client=$_sel_b
				fi
				;;
			'')
				[ "$_sel_b" = 'bg' ] || continue
				_sel_bg=$_sel_c
				[ -z "$_sel_d" ] || _sel_bg="$_sel_bg|$_sel_d"
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
	_sel_rest=$_sel_bg
	while [ -n "$_sel_rest" ]; do
		_sel_rec=${_sel_rest%%|*}
		case "$_sel_rest" in
			*'|'*) _sel_rest=${_sel_rest#*|} ;;
			*) _sel_rest='' ;;
		esac
		[ -n "$_sel_rec" ] || continue
		_sel_windows="${_sel_windows}bg:${_sel_rec%%;*}|0|
"
	done
}

# Usage: select_pick N
# Sets _sel_pick (and _sel_pick_session) to the pane id or "bg:<id>" (and
# its session id) at 1-based position N of _sel_windows, or empty if out of
# range.
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
# call (a background session: see select_bg_open). A pane in the viewing
# session is selected with its window; for a pane in another session the
# viewing client (_sel_client, always named: from run-shell or a background
# process the "current client" is ambiguous) is switched to it first. The
# client-session-changed and pane-focus-in hooks then move the sidebar.
select_go() {
	case "$_sel_pick" in
		bg:*)
			select_bg_open "${_sel_pick#bg:}"
			return 0
			;;
	esac
	if [ "$_sel_pick_session" = "$_sel_view_session" ] || [ -z "$_sel_client" ]; then
		tmux set-option -gqu @orchestra_selected_window \; \
			select-window -t "$_sel_pick" \; \
			select-pane -t "$_sel_pick" >/dev/null 2>&1 || true
	else
		tmux set-option -gqu @orchestra_selected_window \; \
			switch-client -c "$_sel_client" -t "$_sel_pick" \; \
			select-window -t "$_sel_pick" \; \
			select-pane -t "$_sel_pick" >/dev/null 2>&1 || true
	fi
}

# Usage: select_move TARGET DELTA [enter]
# Moves the selection DELTA listed rows down (negative: up), clamped at
# both ends. With "enter", clears the selection and shows the result instead
# of storing it (select_go). Two tmux calls. TARGET is as for select_windows.
# Sets SELECT_SIDEBAR_PID. Returns 1 if TARGET cannot be resolved.
select_move() {
	_sel_delta=$2
	_sel_enter=${3:-}

	select_windows "$1" || return 1
	[ -n "$_sel_windows" ] || return 0

	# Count rows and find the selected and active positions (the best
	# ranked pane of the active window, as in lib/render.sh).
	_sel_n=0
	_sel_cur=0
	_sel_active=0
	_sel_rank=9
	while IFS="|" read -r _sel_id _sel_act _sel_sess; do
		[ -n "$_sel_id" ] || continue
		_sel_n=$((_sel_n + 1))
		case "$_sel_act" in
			1 | 2 | 3)
				if [ "$_sel_act" -lt "$_sel_rank" ]; then
					_sel_rank=$_sel_act
					_sel_active=$_sel_n
				fi
				;;
		esac
		[ -n "$_sel_stored" ] && [ "$_sel_id" = "$_sel_stored" ] && _sel_cur=$_sel_n
	done <<EOF
$_sel_windows
EOF
	# Unset or stale: the active pane, or the first listed pane when the
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

# Usage: select_bg_open ID
# Shows background session ID (from _sel_bg) on the viewing client: the
# window already attached to it (@orchestra_bg_id), else a new window in the
# viewing session, in the session's directory and named after it, running
# `claude attach ID`. The window tags itself with @orchestra_bg_id, which
# bin/orchestra-bg-refresh reads to drop the session from the background
# list while it is attached; the window closes when you detach. Two tmux
# calls.
select_bg_open() {
	case "$1" in '' | *[!0-9A-Za-z_-]*) return 0 ;; esac
	_sel_cwd=''
	_sel_name=$1
	_sel_rest=$_sel_bg
	while [ -n "$_sel_rest" ]; do
		_sel_rec=${_sel_rest%%|*}
		case "$_sel_rest" in
			*'|'*) _sel_rest=${_sel_rest#*|} ;;
			*) _sel_rest='' ;;
		esac
		[ "${_sel_rec%%;*}" = "$1" ] || continue
		# id;state;started;cwd;name
		_sel_rec=${_sel_rec#*;}
		_sel_rec=${_sel_rec#*;}
		_sel_rec=${_sel_rec#*;}
		_sel_cwd=${_sel_rec%%;*}
		case "$_sel_rec" in *';'*) _sel_name=${_sel_rec#*;} ;; esac
		[ -n "$_sel_name" ] || _sel_name=$1
		break
	done
	[ -n "$_sel_cwd" ] && [ -d "$_sel_cwd" ] || _sel_cwd=$HOME

	_sel_attached=$(tmux list-windows -a -F '#{@orchestra_bg_id}|#{window_id}' 2>/dev/null) || _sel_attached=''
	while IFS='|' read -r _sel_a _sel_b; do
		[ "$_sel_a" = "$1" ] || continue
		# Already attached: show it like any other window (switch-client
		# resolves its session).
		if [ -n "$_sel_client" ]; then
			tmux set-option -gqu @orchestra_selected_window \; \
				switch-client -c "$_sel_client" -t "$_sel_b" \; \
				select-window -t "$_sel_b" >/dev/null 2>&1 || true
		else
			tmux set-option -gqu @orchestra_selected_window \; select-window -t "$_sel_b" >/dev/null 2>&1 || true
		fi
		return 0
	done <<EOF
$_sel_attached
EOF

	# If attach fails, the window stays open on the error until Enter.
	tmux set-option -gqu @orchestra_selected_window \; \
		new-window -t "$_sel_view_session:" -c "$_sel_cwd" -n "$_sel_name" \
		"tmux set-option -wq -t \"\$TMUX_PANE\" @orchestra_bg_id $1; claude attach $1 || { printf '\\nclaude attach $1 failed. Enter closes this window. '; read -r _; }" \
		>/dev/null 2>&1 || true
}

# Usage: select_row TARGET LINE
# Shows what sits at 0-based sidebar LINE (a click), as Enter does: pane
# blocks are 3 lines each (or a 1-line placeholder when there are none),
# then, when there are background sessions, a 1-line separator and a 3-line
# block per session (lib/render.sh). The separator and out of range lines
# are no-ops. Three tmux calls at most.
select_row() {
	select_windows "$1" || return 0
	if [ "$_sel_nwin" -gt 0 ]; then
		_sel_top=$((_sel_nwin * 3))
	else
		_sel_top=1
	fi
	if [ "$2" -lt "$_sel_top" ]; then
		[ "$_sel_nwin" -gt 0 ] || return 0
		select_pick $(($2 / 3 + 1))
	else
		_sel_line=$(($2 - _sel_top - 1))
		[ "$_sel_line" -ge 0 ] || return 0
		select_pick $((_sel_nwin + _sel_line / 3 + 1))
	fi
	[ -n "$_sel_pick" ] || return 0
	select_go
}

# Usage: select_reset
# Clears the selection. One tmux call; sets SELECT_SIDEBAR_PID.
# shellcheck disable=SC2034 # SELECT_SIDEBAR_PID is read by the caller.
select_reset() {
	SELECT_SIDEBAR_PID=$(tmux set-option -gqu @orchestra_selected_window \; show-options -gqv @orchestra_sidebar_pid 2>/dev/null) || SELECT_SIDEBAR_PID=''
}
