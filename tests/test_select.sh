#!/bin/sh
# Session ids ($1) and $TMUX_PANE are literal tmux output and arguments here.
# shellcheck disable=SC2016
# Click mapping and background-session opening in lib/select.sh, against a
# stub tmux (a shell function) so no tmux server is needed.
set -eu

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$REPO_DIR/lib/select.sh"

log=$(mktemp "${TMPDIR:-/tmp}/orchestra-select.XXXXXX")
trap 'rm -f "$log"' EXIT

# select_windows reads this dump; list-windows (select_bg_open) reads
# $attached. Every other call is appended to $log, one per line.
dump=''
attached=''
tmux() {
	case "$*" in
		*list-panes*) printf '%s\n' "$dump" ;;
		*list-windows*) printf '%s\n' "$attached" ;;
		*) printf '%s\n' "$*" >>"$log" ;;
	esac
}

fail() {
	printf 'select: %s\n--- log ---\n%s\n' "$1" "$(cat "$log")" >&2
	exit 1
}

# Clicks LINE and checks the one tmux call it made contains WANT (empty:
# no call).
check_click() {
	: >"$log"
	select_row '%9' "$1"
	got=$(cat "$log")
	if [ -z "$2" ]; then
		[ -z "$got" ] || fail "line $1: expected no call"
	else
		case "$got" in *"$2"*) ;; *) fail "line $1: expected \"$2\"" ;; esac
	fi
}

# Three Claude panes: %1 (the active pane) and %2 in one window, %3 in
# another; %4 runs no Claude. Then two background sessions: lines 0-8 are
# panes, 9 the separator, 10-12 and 13-15 sessions.
dump='$1|123|
%1|1|1|$1
%2|3|1|$1
%3|0|1|$1
%4|0|0|$1
>100|/dev/ttys001
|bg|a1;done;1799000000;/;first job|b2;blocked;;/no/such/dir;'
check_click 0 'select-window -t %1 ; select-pane -t %1'
check_click 3 'select-window -t %2 ; select-pane -t %2'
check_click 8 'select-pane -t %3'
check_click 9 ''
check_click 10 'new-window -t $1: -c / -n first job'
check_click 12 'claude attach a1'
check_click 15 'new-window -t $1: -c '"$HOME"' -n b2'
check_click 16 ''

# The new window tags itself, so the refresh drops the session.
check_click 10 'set-option -wq -t "$TMUX_PANE" @orchestra_bg_id a1'

# Already attached: show that window instead of opening another.
attached='|@1
a1|@7'
check_click 11 'switch-client -c /dev/ttys001 -t @7'
attached=''

# A pane in another session switches the client to it.
dump=$(printf '%s\n' "$dump" | sed 's/^%3|0|1|$1$/%3|0|1|$2/')
check_click 6 'switch-client -c /dev/ttys001 -t %3 ; select-window -t %3 ; select-pane -t %3'

# Keyboard: the selection starts on the active pane, walks the panes of one
# window, then into the sessions, and Enter opens one.
: >"$log"
select_move '%9' 1
case "$(cat "$log")" in *'@orchestra_selected_window %2'*) ;; *) fail 'move to the second pane' ;; esac
: >"$log"
select_move '%9' 3
case "$(cat "$log")" in *'@orchestra_selected_window bg:a1'*) ;; *) fail 'move into background sessions' ;; esac
dump=$(printf '%s\n' "$dump" | sed '1s/.*/$1|123|bg:a1/')
: >"$log"
select_move '%9' 0 enter
case "$(cat "$log")" in *'claude attach a1'*) ;; *) fail 'enter on a background session' ;; esac

# The active pane runs no Claude (the sidebar): the previously active one
# (rank 2) is where the selection starts.
dump='$1|123|
%1|3|1|$1
%2|2|1|$1
%5|1|0|$1'
: >"$log"
select_move '%9' 0 enter
case "$(cat "$log")" in *'select-pane -t %2'*) ;; *) fail 'enter on the previously active pane' ;; esac

# No windows: the placeholder is one line, so the separator is line 1.
dump='$1|123|
>100|/dev/ttys001
|bg|a1;done;;/;job'
check_click 0 ''
check_click 1 ''
check_click 2 'claude attach a1'

# An id that is not a plain token is never put in a shell command.
dump='$1|123|
|bg|a1$(x);done;;/;job'
check_click 2 ''

printf 'test_select: ok\n'
