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
orphan_panes=''
tmux() {
	case "$*" in
		*'list-panes -s'*) printf '%s\n' "$orphan_panes" ;;
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

# A pane that runs no Claude but has a session to resume (claude flag 2, the
# id last) is listed like the others; Enter types the resume command into it
# and drops the pending id. A pane with flag 0 stays out of the list, and an
# id that is not a plain token is never typed.
dump='$1|123|
%1|1|1|$1|
%2|3|2|$1|aaaa-1111
%4|0|0|$1|stale-id
>100|/dev/ttys001'
check_click 0 'select-pane -t %1'
check_click 3 'select-window -t %2 ; select-pane -t %2'
check_click 3 'send-keys -t %2 claude --resume aaaa-1111 Enter ; set-option -pqu -t %2 @ab_resume_id'
check_click 6 ''
: >"$log"
select_click_running=$(printf '%s' "$_sel_windows" | grep -c 'aaaa-1111')
[ "$select_click_running" -eq 1 ] || fail 'the resume id travels with its pane'
: >"$log"
select_row '%9' 0
case "$(cat "$log")" in *'send-keys'*) fail 'a running Claude pane is never typed into' ;; esac
dump='$1|123|
%2|3|2|$1|x$(y)
>100|/dev/ttys001'
: >"$log"
select_row '%9' 0
case "$(cat "$log")" in *'send-keys'*) fail 'an id that is not a plain token is not typed' ;; esac

# Orphaned sessions come after the background ones, each section a separator
# line and 3 lines per record: two panes (lines 0-5), one background session
# (6 separator, 7-9), two orphans (10 separator, 11-13 and 14-16). o1 is
# dead; o2's process (pid 99999999) is alive and asks before it is killed.
dump='$1|123|
%1|1|1|$1|
%2|3|1|$1|
>100|/dev/ttys001
|bg|a1;done;1799000000;/;first job
|orphan|o1;111;1799000000;/tmp;n;0|o2;99999999;1799000100;/;m;1'
check_click 7 'claude attach a1'
check_click 10 ''
check_click 11 'new-window -t $1: -c /tmp -n tmp claude --resume o1; exec'
check_click 13 'claude --resume o1'
check_click 14 'confirm-before -t /dev/ttys001 -p pid 99999999 still runs this session; kill it and resume? (y/n) run-shell -b '
check_click 14 'orchestra-orphan-resume o2 $1'
check_click 16 'orchestra-orphan-resume o2 $1'
check_click 17 ''
# An id that is not a plain token is never put in a command.
dump='$1|123|
>100|/dev/ttys001
|orphan|o$(x);111;1799000000;/tmp;n;0'
check_click 2 ''

# The target of a resume is the one shell pane (not the sidebar, not running
# Claude) in the directory or in a window named after it; it gets the command
# typed in, with a cd when it is elsewhere. Several candidates open a window.
dump='$1|123|
>100|/dev/ttys001
|orphan|o1;111;1799000000;/tmp;n;0'
orphan_panes='%7|0|1|0|/tmp|other
%8|0|1|0|/home|elsewhere
%9|1|1|0|/tmp|tmp
%6|0|1|1|/tmp|tmp
%5|0|0|0|/tmp|tmp'
check_click 2 'select-window -t %7 ; select-pane -t %7 ; send-keys -t %7 claude --resume o1 Enter'
orphan_panes='%8|0|1|0|/home|tmp'
check_click 2 "send-keys -t %8 cd '/tmp' && claude --resume o1 Enter"
orphan_panes='%7|0|1|0|/tmp|other
%8|0|1|0|/home|tmp'
check_click 2 'new-window -t $1: -c /tmp -n tmp'
orphan_panes=''

# Keyboard: the selection walks into the orphans and Enter resumes; "x"
# (dismiss) hides one, on an orphan only. The id joins the dismissed list and
# its record leaves the option at once.
dump='$1|123|orphan:o1|old1
%1|1|1|$1|
>100|/dev/ttys001
|orphan|o1;111;1799000000;/tmp;n;0|o2;112;1799000100;/x;m;0'
: >"$log"
select_move '%9' 0 enter
case "$(cat "$log")" in *'claude --resume o1'*) ;; *) fail 'enter on an orphan' ;; esac
: >"$log"
select_move '%9' 0 dismiss
case "$(cat "$log")" in *'@orchestra_orphan_agents o2;112;1799000100;/x;m;0'*'@orchestra_orphan_dismissed old1 o1'*) ;; *) fail 'dismiss an orphan' ;; esac
dump='$1|123|o2x
%1|1|1|$1|
>100|/dev/ttys001
|orphan|o2;112;1799000100;/x;m;0'
: >"$log"
select_move '%9' 0 dismiss
case "$(cat "$log")" in *'orphan_dismissed'*) fail 'dismiss on a pane row does nothing' ;; esac
dump='$1|123|orphan:o2
%1|1|1|$1|
>100|/dev/ttys001
|orphan|o2;112;1799000100;/x;m;0'
: >"$log"
select_move '%9' 0 dismiss
case "$(cat "$log")" in *'set-option -gqu @orchestra_orphan_agents ; set-option -gq @orchestra_orphan_dismissed o2'*) ;; *) fail 'dismissing the last orphan unsets the list' ;; esac

printf 'test_select: ok\n'
