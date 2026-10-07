#!/bin/sh
set -eu

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-cli.XXXXXX")
# One socket per run, so concurrent runs (two checkouts, two agents) do not
# share a tmux server and kill each other's on cleanup.
SOCKET=orchestra-test-$$

client_pid=''
# Stops the headless client (see below) and the sleep that feeds its stdin.
stop_client() {
    if [ -n "$client_pid" ]; then
        kill "$client_pid" >/dev/null 2>&1 || true
        client_pid=''
    fi
    if [ -s "$TMP_DIR/client-stdin.pid" ]; then
        kill "$(cat "$TMP_DIR/client-stdin.pid")" >/dev/null 2>&1 || true
        rm -f "$TMP_DIR/client-stdin.pid"
    fi
}
cleanup() {
    PATH=$ORIGINAL_PATH tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    stop_client
    rm -rf "$TMP_DIR"
    rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"
}
trap cleanup EXIT INT TERM

ORIGINAL_PATH=$PATH
cat >"$TMP_DIR/tmux" <<EOF
#!/bin/sh
exec $(command -v tmux) -L "$SOCKET" "\$@"
EOF
chmod +x "$TMP_DIR/tmux"
PATH=$TMP_DIR:$REPO_DIR/bin:$PATH
# shellcheck disable=SC1091
. "$REPO_DIR/lib/select.sh"

# A fake Claude Code: a copy of sleep named like a version, which is what
# pane_current_command shows for the real (version-named) binary. macOS kills
# a copied platform binary unless it is re-signed.
cp "$(command -v sleep)" "$TMP_DIR/2.1.999"
if command -v codesign >/dev/null 2>&1; then
    codesign -f -s - "$TMP_DIR/2.1.999" >/dev/null 2>&1 || true
fi

# Usage: start_claude WINDOW_ID
# Splits a fake Claude pane into WINDOW_ID and waits until tmux reports it.
start_claude() {
    claude_pane=$(tmux split-window -d -t "$1" -P -F '#{pane_id}' "$TMP_DIR/2.1.999 600")
    tries=0
    until [ "$(tmux display-message -p -t "$claude_pane" '#{pane_current_command}')" = '2.1.999' ]; do
        tries=$((tries + 1))
        [ "$tries" -lt 50 ] || { printf 'fake claude pane did not start\n' >&2; exit 1; }
        sleep 0.1
    done
}

tmux -f /dev/null new-session -d -s orchestra-tests
window_id=$(tmux display-message -p -t orchestra-tests '#{window_id}')

assert_eq() {
    expected=$1
    actual=$2
    message=$3
    if [ "$expected" != "$actual" ]; then
        printf 'assertion failed: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
        exit 1
    fi
}

# Usage: wait_eq EXPECTED MESSAGE COMMAND...
# Polls COMMAND (hooks and the renderer act asynchronously) for up to 5 s
# until it prints EXPECTED.
wait_eq() {
    wait_expected=$1
    wait_message=$2
    shift 2
    wait_tries=0
    while :; do
        wait_actual=$("$@" 2>/dev/null || true)
        [ "$wait_actual" != "$wait_expected" ] || return 0
        wait_tries=$((wait_tries + 1))
        [ "$wait_tries" -lt 50 ] || assert_eq "$wait_expected" "$wait_actual" "$wait_message"
        sleep 0.1
    done
}

# Prints "session|window_id" of a pane or client target.
where_pane() {
    tmux display-message -p -t "$1" '#{session_name}|#{window_id}'
}
# "left|height|window_height" of a pane: the sidebar must sit at the left edge
# and span the full window height.
sidebar_geometry() {
    tmux display-message -p -t "$1" '#{pane_left}|#{pane_height}|#{window_height}'
}
sidebar_at_left_edge() {
    geom=$(sidebar_geometry "$1")
    left=${geom%%|*}
    rest=${geom#*|}
    [ "$left" = 0 ] && [ "${rest%%|*}" = "${rest#*|}" ] && printf ok
}
where_client() {
    tmux list-clients -F '#{client_session}|#{window_id}'
}

# Prints 1 if the sidebar capture lists the Claude windows of both sessions
# and none of the plain windows.
sidebar_lists_both() {
    shot=$(tmux capture-pane -p -t "$1")
    case "$shot" in *plainwin* | *otherplain*) printf 0; return ;; esac
    case "$shot" in *orchestra-tests:first*) ;; *) printf 0; return ;; esac
    case "$shot" in *other:otherclaude*) printf 1 ;; *) printf 0 ;; esac
}

# Prints how many sidebar rows are titled after the first window (its pane
# suffix may be cut off at the sidebar's width).
first_window_rows() {
    tmux capture-pane -p -t "$1" | grep -c 'orchestra-tests:fi' || true
}

"$REPO_DIR/orchestra.tmux"
mouse_binding=$(tmux list-keys -T root MouseDown1Pane)
case "$mouse_binding" in
    *"if-shell -F -t ="*"orchestra-click #{mouse_y} #{session_name}"*)
        :
        ;;
    *)
        printf 'assertion failed: MouseDown1Pane targets the pane under the mouse\nactual:   %s\n' "$mouse_binding" >&2
        exit 1
        ;;
esac

orchestra set-status phase build --icon '*' --color cyan --window "$window_id"
assert_eq 'build' "$(tmux show-options -v -w -t "$window_id" @ab_status_phase)" 'status text is written'
assert_eq '*' "$(tmux show-options -v -w -t "$window_id" @ab_status_phase__icon)" 'status icon is written'
assert_eq 'cyan' "$(tmux show-options -v -w -t "$window_id" @ab_status_phase__color)" 'status color is written'

list_output=$(orchestra list-status --window "$window_id")
assert_eq 'phase	build' "$list_output" 'status list reports written key'

orchestra clear-status phase --window "$window_id"
assert_eq '' "$(tmux show-options -v -w -t "$window_id" @ab_status_phase 2>/dev/null || printf '')" 'status text is cleared'

orchestra set-progress 0.42 --label 'Compile' --window "$window_id"
assert_eq '0.42' "$(tmux show-options -v -w -t "$window_id" @ab_progress)" 'progress is written'
assert_eq 'Compile' "$(tmux show-options -v -w -t "$window_id" @ab_progress_label)" 'progress label is written'
orchestra clear-progress --window "$window_id"
assert_eq '' "$(tmux show-options -v -w -t "$window_id" @ab_progress 2>/dev/null || printf '')" 'progress is cleared'

cat >"$TMP_DIR/notifier" <<'EOF'
#!/bin/sh
printf '%s|%s|%s\n' "$1" "$2" "$3" >"__OUTPUT__"
EOF
sed "s#__OUTPUT__#$TMP_DIR/notifier.out#g" "$TMP_DIR/notifier" >"$TMP_DIR/notifier.real"
mv "$TMP_DIR/notifier.real" "$TMP_DIR/notifier"
chmod +x "$TMP_DIR/notifier"
ORCHESTRA_NOTIFIER="$TMP_DIR/notifier" orchestra notify --title 'Build' --body 'done' --subtitle 'CI' --window "$window_id"
assert_eq '1' "$(tmux show-options -v -w -t "$window_id" @ab_unread)" 'notify marks unread'
assert_eq 'Build — CI: done' "$(tmux show-options -v -w -t "$window_id" @ab_last_notification)" 'notify stores summary'
assert_eq 'Build|done|CI' "$(cat "$TMP_DIR/notifier.out")" 'notify calls notifier shim'

# --quiet still writes option state but skips the notifier shim entirely.
tmux set-option -wqu -t "$window_id" @ab_unread
rm -f "$TMP_DIR/notifier.out"
ORCHESTRA_NOTIFIER="$TMP_DIR/notifier" orchestra notify --title 'Review' --body 'arrived' --quiet --window "$window_id"
assert_eq '1' "$(tmux show-options -v -w -t "$window_id" @ab_unread)" 'notify --quiet marks unread'
assert_eq 'Review: arrived' "$(tmux show-options -v -w -t "$window_id" @ab_last_notification)" 'notify --quiet stores summary'
[ ! -e "$TMP_DIR/notifier.out" ] || { printf 'assertion failed: --quiet must not invoke the notifier shim\n' >&2; exit 1; }

orchestra set-state running --action 'pytest' --window "$window_id"
assert_eq 'running' "$(tmux show-options -v -w -t "$window_id" @ab_agent_state)" 'state is written'
assert_eq 'pytest' "$(tmux show-options -v -w -t "$window_id" @ab_current_action)" 'action is written'
orchestra set-state 'done' --window "$window_id"
assert_eq 'done' "$(tmux show-options -v -w -t "$window_id" @ab_agent_state)" 'done state is written'
assert_eq '' "$(tmux show-options -v -w -t "$window_id" @ab_current_action 2>/dev/null || printf '')" 'done clears action'
case "$(tmux show-options -v -w -t "$window_id" @ab_finished_at)" in
    ''|*[!0-9]*) assert_eq 'epoch seconds' "$(tmux show-options -v -w -t "$window_id" @ab_finished_at)" 'done records @ab_finished_at' ;;
esac
# A waiting after the turn ended keeps the finish time; one that interrupts
# a running turn records a new one.
tmux set-option -wq -t "$window_id" @ab_finished_at 5
orchestra set-state waiting --window "$window_id"
assert_eq '5' "$(tmux show-options -v -w -t "$window_id" @ab_finished_at)" 'idle waiting keeps the finish time'
orchestra set-state running --window "$window_id"
orchestra set-state waiting --window "$window_id"
if [ "$(tmux show-options -v -w -t "$window_id" @ab_finished_at)" = '5' ]; then
    assert_eq 'a new time' '5' 'waiting during a turn records the finish time'
fi
# Background work, compaction and API errors are states of their own; the
# turn ending with background work running or on an error records the
# finish time, compaction does not.
for state in background compacting error; do
    tmux set-option -wq -t "$window_id" @ab_finished_at 5
    orchestra set-state "$state" --window "$window_id"
    assert_eq "$state" "$(tmux show-options -v -w -t "$window_id" @ab_agent_state)" "$state state is written"
    stamp=$(tmux show-options -v -w -t "$window_id" @ab_finished_at)
    if [ "$state" = compacting ]; then
        assert_eq '5' "$stamp" 'compacting keeps the finish time'
    elif [ "$stamp" = '5' ]; then
        assert_eq 'a new time' '5' "$state records the finish time"
    fi
done
if orchestra set-state sleeping --window "$window_id" 2>/dev/null; then
    assert_eq 'usage error' 'accepted' 'set-state rejects an unknown state'
fi
orchestra set-state 'done' --window "$window_id"
orchestra set-prompt 'fix the
flaky | test' --window "$window_id"
assert_eq 'fix the flaky | test' "$(tmux show-options -v -w -t "$window_id" @ab_last_prompt)" 'set-prompt stores the prompt on one line'
orchestra clear-state --window "$window_id"
assert_eq '' "$(tmux show-options -v -w -t "$window_id" @ab_agent_state 2>/dev/null || printf '')" 'clear-state clears agent state'

# --pane writes pane options and leaves the window's alone; a pane without a
# value of its own shows its window's in formats.
pane0=$(tmux display-message -p -t "$window_id.0" '#{pane_id}')
orchestra set-state running --action 'pane job' --pane "$pane0"
assert_eq 'running' "$(tmux show-options -v -p -t "$pane0" @ab_agent_state)" '--pane writes the pane option'
assert_eq '' "$(tmux show-options -v -w -t "$window_id" @ab_agent_state 2>/dev/null || printf '')" '--pane does not write the window option'
orchestra set-status phase lint --pane "$pane0"
assert_eq 'phase	lint' "$(orchestra list-status --pane "$pane0")" 'list-status --pane reads the pane'
assert_eq '' "$(orchestra list-status --window "$window_id")" 'list-status --window does not see pane status'
orchestra clear-status phase --pane "$pane0"
orchestra clear-state --pane "$pane0"
assert_eq '' "$(tmux show-options -v -p -t "$pane0" @ab_agent_state 2>/dev/null || printf '')" 'clear-state --pane clears the pane option'
orchestra set-state waiting --window "$window_id"
assert_eq 'waiting' "$(tmux display-message -p -t "$pane0" '#{@ab_agent_state}')" 'a pane without its own state shows the window state'
orchestra clear-state --window "$window_id"
if orchestra set-state running --pane "$window_id" 2>/dev/null; then
    assert_eq 'usage error' 'accepted' '--pane rejects a non-pane id'
fi

# Claude Code hook dispatcher. Events arrive as JSON on stdin; the window
# comes from ORCHESTRA_WINDOW_ID since the test shell has no TMUX_PANE.
hook() {
    printf '%s' "$2" | env -u TMUX_PANE ORCHESTRA_WINDOW_ID="$window_id" orchestra-claude-hook "$1"
}
opt() {
    tmux show-options -v -w -t "$window_id" "$1" 2>/dev/null || printf ''
}
hook session-start '{"source":"clear"}'
assert_eq 'clear' "$(opt @ab_session_source)" 'session-start after /clear marks the session empty'
assert_eq '' "$(opt @ab_last_prompt)" 'session-start after /clear drops the old prompt'
hook prompt '{"prompt":"run the\ntests"}'
assert_eq 'run the tests' "$(opt @ab_last_prompt)" 'prompt hook stores the prompt'
hook prompt '{"prompt":"<task-notification> <task-id>b1</task-id>"}'
assert_eq 'run the tests' "$(opt @ab_last_prompt)" 'prompt hook keeps the typed prompt over a task notification'
assert_eq '' "$(opt @ab_session_source)" 'prompt hook drops the empty-session marker'
assert_eq 'running' "$(opt @ab_agent_state)" 'prompt hook marks running'
hook pre-tool '{"tool_name":"Bash","tool_input":{"command":"make test","description":"Run the  tests"}}'
assert_eq 'Bash: Run the tests' "$(opt @ab_current_action)" 'pre-tool prefers the tool description'
hook notification '{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
assert_eq 'waiting' "$(opt @ab_agent_state)" 'a permission prompt marks waiting'
assert_eq 'allow? Bash: Run the tests' "$(opt @ab_current_action)" 'a permission prompt names the pending tool'
hook post-tool '{"tool_name":"Bash"}'
assert_eq 'running' "$(opt @ab_agent_state)" 'an approved tool call goes back to running'
assert_eq 'Bash: done' "$(opt @ab_current_action)" 'post-tool names the tool'
hook post-tool '{"tool_name":"Read"}'
assert_eq 'Bash: done' "$(opt @ab_current_action)" 'post-tool leaves a running window alone'
hook notification '{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
hook tool-failure '{"tool_name":"Bash","is_interrupt":true}'
assert_eq '' "$(opt @ab_agent_state)" 'rejecting a permission prompt (an interrupt) clears the state'
hook notification '{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
hook tool-failure '{"tool_name":"Bash","is_interrupt":false,"error":"exit 1"}'
assert_eq 'running' "$(opt @ab_agent_state)" 'a failed tool run goes back to running'
hook notification '{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
hook permission-denied '{"tool_name":"Bash","reason":"denied"}'
assert_eq '' "$(opt @ab_agent_state)" 'permission-denied clears the state'
hook notification '{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
hook stop '{}'
assert_eq '' "$(opt @ab_agent_state)" 'stop clears the state'
assert_eq '1' "$(opt @ab_unread)" 'stop marks a window nobody is looking at unread'
hook notification '{"notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
assert_eq '' "$(opt @ab_agent_state)" 'the idle reminder does not mark waiting'
hook stop '{"background_tasks":[{"id":"a1","type":"local_agent","status":"running","description":"Review  the diff"},{"id":"b2","type":"local_bash","status":"completed","description":"old"}]}'
assert_eq 'background' "$(opt @ab_agent_state)" 'stop with a running background task marks background'
assert_eq '1 background: Review the diff' "$(opt @ab_current_action)" 'background names the running task'
hook stop '{"background_tasks":[{"id":"b2","type":"local_bash","status":"completed","description":"old"}]}'
assert_eq '' "$(opt @ab_agent_state)" 'stop with only finished background tasks clears the state'
hook stop '{"background_tasks":[{"id":"c3","type":"local_agent","status":"idle","description":"Open the upstream PR"}]}'
assert_eq '' "$(opt @ab_agent_state)" 'stop with only an idle background agent clears the state'
hook pre-compact '{"trigger":"auto"}'
assert_eq 'compacting' "$(opt @ab_agent_state)" 'pre-compact marks compacting'
assert_eq 'compacting (auto)' "$(opt @ab_current_action)" 'compacting names the trigger'
hook post-compact '{"trigger":"auto"}'
assert_eq 'running' "$(opt @ab_agent_state)" 'automatic compaction resumes running'
hook pre-compact '{"trigger":"manual"}'
hook post-compact '{"trigger":"manual"}'
assert_eq '' "$(opt @ab_agent_state)" '/compact ends idle'
hook stop-failure '{"error":"rate_limit"}'
assert_eq 'error' "$(opt @ab_agent_state)" 'stop-failure marks error'
assert_eq 'error: rate_limit' "$(opt @ab_current_action)" 'error names the failure'
assert_eq '1' "$(opt @ab_unread)" 'stop-failure marks a window nobody is looking at unread'
hook stop '{}'
assert_eq '' "$(opt @ab_agent_state)" 'the idle reminder does not mark waiting'
printf '%s\n' '{"type":"user","message":{"content":"first ask"}}' \
    '{"type":"user","message":{"content":[{"type":"text","text":"second ask"}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}' \
    '{"type":"user","message":{"content":"<command-name>/model</command-name>"}}' >"$TMP_DIR/transcript.jsonl"
hook session-start "{\"source\":\"resume\",\"transcript_path\":\"$TMP_DIR/transcript.jsonl\"}"
assert_eq 'second ask' "$(opt @ab_last_prompt)" 'session-start on resume restores the last typed prompt'

# The Claude pane detection format matches the version-named binary only.
start_claude "$window_id"
window1_claude_pane=$claude_pane
assert_eq '1' "$(tmux display-message -p -t "$window1_claude_pane" "$ORCHESTRA_CLAUDE_PANE")" 'a version-named pane counts as Claude'

# reconcile: a Claude session idle for a few seconds (a rejected permission
# prompt, Esc) clears running/waiting; a fresh idle or a busy one does not.
mkdir -p "$TMP_DIR/claude/sessions"
claude_pid=$(tmux display-message -p -t "$window1_claude_pane" '#{pane_pid}')
claude_status() {
    printf '{"status":"%s","statusUpdatedAt":%s}\n' "$1" "$2" >"$TMP_DIR/claude/sessions/$claude_pid.json"
}
reconcile() {
    CLAUDE_CONFIG_DIR="$TMP_DIR/claude" orchestra-claude-hook reconcile
}
now_ms=$(($(date +%s) * 1000))
orchestra set-state waiting --action 'allow? Bash: touch' --window "$window_id"
claude_status busy $((now_ms - 60000))
reconcile
assert_eq 'waiting' "$(opt @ab_agent_state)" 'reconcile leaves a busy session alone'
claude_status idle "$now_ms"
reconcile
assert_eq 'waiting' "$(opt @ab_agent_state)" 'reconcile waits before trusting a fresh idle'
claude_status idle $((now_ms - 60000))
tmux set-option -wq -t "$window_id" @ab_unread 1
reconcile
assert_eq '' "$(opt @ab_agent_state)" 'reconcile clears waiting once the session is idle'
assert_eq '' "$(opt @ab_unread)" 'reconcile drops the unread the permission prompt left'
# Each Claude pane is reconciled on its own session: an idle pane's state is
# cleared while a busy pane in the same window keeps its own.
start_claude "$window_id"
second_pane=$claude_pane
second_pid=$(tmux display-message -p -t "$second_pane" '#{pane_pid}')
printf '{"status":"busy","statusUpdatedAt":%s}\n' $((now_ms - 60000)) >"$TMP_DIR/claude/sessions/$second_pid.json"
orchestra set-state waiting --action 'allow? Bash: rm' --pane "$window1_claude_pane"
orchestra set-state running --action 'Bash: sleep' --pane "$second_pane"
reconcile
assert_eq '' "$(tmux show-options -v -p -t "$window1_claude_pane" @ab_agent_state 2>/dev/null || printf '')" 'reconcile clears the idle pane'
assert_eq 'running' "$(tmux show-options -v -p -t "$second_pane" @ab_agent_state)" 'reconcile keeps the busy pane in the same window'
tmux kill-pane -t "$second_pane"
rm -f "$TMP_DIR/claude/sessions/$second_pid.json"
orchestra set-state background --action '1 background: x' --window "$window_id"
reconcile
assert_eq 'background' "$(opt @ab_agent_state)" 'reconcile leaves the background state alone'
orchestra clear-state --window "$window_id"
rm -f "$TMP_DIR/claude/sessions/$claude_pid.json"

# Two Claude panes in one window: the hook writes to $TMUX_PANE, so each
# keeps its own state, prompt and unread, and the first event of a session
# drops window-level state an earlier version left (every pane would
# inherit it).
start_claude "$window_id"
second_pane=$claude_pane
pane_hook() {
    printf '%s' "$3" | TMUX_PANE="$1" orchestra-claude-hook "$2"
}
popt() {
    tmux show-options -v -p -t "$1" "$2" 2>/dev/null || printf ''
}
orchestra set-state running --action 'old window state' --window "$window_id"
orchestra set-prompt 'old window prompt' --window "$window_id"
pane_hook "$window1_claude_pane" session-start '{"source":"startup"}'
assert_eq '' "$(opt @ab_agent_state)$(opt @ab_last_prompt)" 'session-start clears window-level state left by an earlier version'
case "$(popt "$window1_claude_pane" @ab_finished_at)" in
    ''|*[!0-9]*) assert_eq 'epoch seconds' "$(popt "$window1_claude_pane" @ab_finished_at)" 'session-start stamps the pane start time' ;;
esac
pane_hook "$window1_claude_pane" prompt '{"prompt":"first pane task"}'
pane_hook "$second_pane" prompt '{"prompt":"second pane task"}'
pane_hook "$second_pane" notification '{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
assert_eq 'running' "$(popt "$window1_claude_pane" @ab_agent_state)" 'the first pane keeps its own state'
assert_eq 'waiting' "$(popt "$second_pane" @ab_agent_state)" 'the second pane keeps its own state'
assert_eq 'first pane task' "$(popt "$window1_claude_pane" @ab_last_prompt)" 'the first pane keeps its own prompt'
assert_eq 'second pane task' "$(popt "$second_pane" @ab_last_prompt)" 'the second pane keeps its own prompt'
assert_eq '' "$(opt @ab_agent_state)" 'pane hook events do not write the window'
assert_eq '1' "$(popt "$second_pane" @ab_unread)" 'a permission prompt marks its own pane unread'
tmux set-option -pqu -t "$second_pane" @ab_unread
pane_hook "$window1_claude_pane" stop '{}'
assert_eq '1' "$(popt "$window1_claude_pane" @ab_unread)" 'stop marks the pane unread'
assert_eq '' "$(popt "$second_pane" @ab_unread)" 'the other pane is not marked unread'
case "$(popt "$window1_claude_pane" @ab_finished_at)" in
    ''|*[!0-9]*) assert_eq 'epoch seconds' "$(popt "$window1_claude_pane" @ab_finished_at)" 'stop records the pane finish time' ;;
esac
pane_list=$(tmux list-panes -t "$window_id" -F "#{pane_id}=#{@ab_agent_state}" | grep -e "^$window1_claude_pane=" -e "^$second_pane=" | sort | tr '\n' ' ')
expected_list=$(printf '%s\n' "$window1_claude_pane=" "$second_pane=waiting" | sort | tr '\n' ' ')
assert_eq "$expected_list" "$pane_list" 'list-panes formats read each pane its own state'
assert_eq '0' "$(tmux display-message -p -t "$window_id.0" "$ORCHESTRA_CLAUDE_PANE")" 'a shell pane does not count as Claude'

# The sidebar lists only Claude windows, so clicks and the keyboard
# selection skip the others: a plain shell window, and one with a stale
# "running" state left behind by a Claude that exited without its Stop hook.
plain_id=$(tmux new-window -d -t orchestra-tests -P -F '#{window_id}')
window2_info=$(tmux new-window -t orchestra-tests -P -F '#{window_id}|#{pane_id}')
window2_id=${window2_info%%|*}
pane2_id=${window2_info#*|}
start_claude "$window2_id"
window2_pane=$claude_pane
stale_id=$(tmux new-window -d -t orchestra-tests -P -F '#{window_id}')
orchestra set-state running --action 'Bash: ls' --window "$stale_id"

# Mouse click: orchestra-click <y> <session> selects the listed pane at
# block y/3: the two Claude panes of the first window (in pane order), then
# the second Claude window, skipping the plain window.
w1_panes=$(tmux list-panes -t "$window_id" -F '#{pane_id}' | grep -x -e "$window1_claude_pane" -e "$second_pane")
w1_first=$(printf '%s\n' "$w1_panes" | sed -n 1p)
w1_second=$(printf '%s\n' "$w1_panes" | sed -n 2p)
where_active() {
    tmux display-message -p -t orchestra-tests '#{window_id}|#{pane_id}'
}
tmux select-window -t "$window_id"
active_before=$(tmux display-message -p -t orchestra-tests '#{window_id}')
assert_eq "$window_id" "$active_before" 'window 1 is active before click'
orchestra-click 3 orchestra-tests
assert_eq "$window_id|$w1_second" "$(where_active)" 'orchestra-click selects the second Claude pane of a window'
# Y=6 → block 2 → second Claude window, skipping the plain window.
orchestra-click 6 orchestra-tests
assert_eq "$window2_id|$window2_pane" "$(where_active)" 'orchestra-click skips non-Claude windows'
# Y=0 → block 0 → first pane.
orchestra-click 0 orchestra-tests
assert_eq "$window_id|$w1_first" "$(where_active)" 'orchestra-click y=0 selects the first pane'
# Y=9 → block 3 → only the stale and plain windows remain, neither listed.
orchestra-click 9 orchestra-tests
assert_eq "$window_id|$w1_first" "$(where_active)" 'orchestra-click past the last Claude pane is a no-op'
orchestra-click 999 orchestra-tests
assert_eq "$window_id|$w1_first" "$(where_active)" 'orchestra-click out-of-range is a no-op'

# Keyboard selection: orchestra-select moves @orchestra_selected_window across the
# Claude panes without switching windows, clamps at both ends, and enter
# selects it.
window3_id=$(tmux new-window -d -t orchestra-tests -P -F '#{window_id}')
start_claude "$window3_id"
window3_pane=$claude_pane
tmux select-window -t "$window_id"
orchestra-select up orchestra-tests
assert_eq "$w1_first" "$(tmux show-options -gv @orchestra_selected_window)" 'selection starts on the active pane and clamps at the top'
orchestra-select down orchestra-tests
assert_eq "$w1_second" "$(tmux show-options -gv @orchestra_selected_window)" 'selection walks the Claude panes of one window'
orchestra-select down orchestra-tests
assert_eq "$window2_pane" "$(tmux show-options -gv @orchestra_selected_window)" 'selection skips the plain window'
orchestra-select down orchestra-tests
assert_eq "$window3_pane" "$(tmux show-options -gv @orchestra_selected_window)" 'selection skips the stale-state window'
orchestra-select down orchestra-tests
assert_eq "$window3_pane" "$(tmux show-options -gv @orchestra_selected_window)" 'selection clamps at the bottom'
assert_eq "$window_id" "$(tmux display-message -p -t orchestra-tests '#{window_id}')" 'moving the selection does not switch windows'
orchestra-select enter orchestra-tests
assert_eq "$window3_id|$window3_pane" "$(where_active)" 'enter selects the highlighted pane'
assert_eq '' "$(tmux show-options -gv @orchestra_selected_window 2>/dev/null || printf '')" 'enter clears the selection'
tmux set-option -gq @orchestra_selected_window '%999'
orchestra-select up orchestra-tests
assert_eq "$window2_pane" "$(tmux show-options -gv @orchestra_selected_window)" 'a stale selection falls back to the active pane'
orchestra-select reset orchestra-tests
assert_eq '' "$(tmux show-options -gv @orchestra_selected_window 2>/dev/null || printf '')" 'reset clears the selection'
# Enter on a pane of the active window that is not its active pane selects
# that pane.
tmux select-window -t "$window_id" \; select-pane -t "$w1_first"
tmux set-option -gq @orchestra_selected_window "$w1_second"
orchestra-select enter orchestra-tests
assert_eq "$window_id|$w1_second" "$(where_active)" 'enter selects another pane of the same window'
# A non-Claude active pane (the shell) in a window with Claude panes: the
# selection starts on the previously active pane.
tmux select-pane -t "$window_id.0"
orchestra-select enter orchestra-tests
assert_eq "$window_id|$w1_second" "$(where_active)" 'a non-Claude active pane falls back to the previously active Claude pane'
tmux select-pane -t "$w1_first"
# From a window without Claude, the selection falls back to the first
# Claude pane.
tmux select-window -t "$plain_id"
orchestra-select down orchestra-tests
assert_eq "$w1_second" "$(tmux show-options -gv @orchestra_selected_window)" 'a non-Claude active window falls back to the first Claude pane'
orchestra-select reset orchestra-tests
tmux select-window -t "$plain_id"
orchestra-select enter orchestra-tests
assert_eq "$window_id|$w1_first" "$(where_active)" 'enter from a non-Claude window selects the first Claude pane'
tmux kill-window -t "$window3_id"
tmux kill-window -t "$plain_id"
tmux kill-window -t "$stale_id"
tmux select-window -t "$window_id"

# Cross-session: the sidebar lists and walks the Claude windows of every
# session (session name, then window index; "other" sorts after
# "orchestra-tests"), and Enter or a click on a window in another session
# switches the viewing client there.
tmux new-session -d -s other
other_plain=$(tmux display-message -p -t other '#{window_id}')
other_claude=$(tmux new-window -d -t other -P -F '#{window_id}')
start_claude "$other_claude"
other_claude_pane=$claude_pane
tmux rename-window -t "$window_id" first \; rename-window -t "$window2_id" second \; \
    rename-window -t "$other_plain" otherplain \; rename-window -t "$other_claude" otherclaude
tmux select-window -t "$window_id"
orchestra-select down orchestra-tests
orchestra-select down orchestra-tests
assert_eq "$window2_pane" "$(tmux show-options -gv @orchestra_selected_window)" 'selection walks the viewing session first'
orchestra-select down orchestra-tests
assert_eq "$other_claude_pane" "$(tmux show-options -gv @orchestra_selected_window)" 'selection continues into the next session, skipping its plain window'
orchestra-select down orchestra-tests
assert_eq "$other_claude_pane" "$(tmux show-options -gv @orchestra_selected_window)" 'selection clamps at the end of the global list'
orchestra-select reset orchestra-tests
# Viewing "other", whose active window is plain: orchestra-tests' active
# window is not the viewing client's, so the selection starts on the first
# listed window.
orchestra-select down other
assert_eq "$w1_second" "$(tmux show-options -gv @orchestra_selected_window)" 'only the viewing session has an active window'
orchestra-select reset orchestra-tests

# The sidebar opens split from the first window's active pane: make that
# the shell, laid out full height so the sidebar has room for a row per
# Claude pane. Done before a client attaches, so no focus hook runs.
tmux set-option -wq -t "$window_id" main-pane-width 60 \; select-layout -t "$window_id" main-vertical \; \
    select-pane -t "$window_id.0"

# A headless client attached to orchestra-tests, so Enter has a client to
# switch and the focus hooks fire. Its stdin must never reach EOF: script(1)
# forwards EOF on its stdin as ^D into the pty, and the client types it into
# the active pane, which kills that shell at a random point of the test (and
# the focus change then clears the sidebar selection). A sleep that never
# writes keeps stdin open; its pid is recorded so cleanup can stop it.
{ sh -c 'echo "$$" >"$1"; exec sleep 600' sh "$TMP_DIR/client-stdin.pid"; } |
    script -q /dev/null tmux attach -t orchestra-tests >/dev/null 2>&1 &
client_pid=$!
wait_eq "orchestra-tests|$window_id" 'a headless client attaches' where_client

# With the client showing the window, an API error does not mark it unread.
tmux set-option -wqu -t "$window_id" @ab_unread
hook stop-failure '{"error":"rate_limit"}'
assert_eq 'error' "$(opt @ab_agent_state)" 'stop-failure marks error in a watched window'
assert_eq '' "$(opt @ab_unread)" 'stop-failure skips unread for a window someone is looking at'
orchestra clear-state --window "$window_id"

# One sidebar per server, opened in the first window.
first_pane=$(tmux display-message -p -t "$window_id.0" '#{pane_id}')
TMUX_PANE=$first_pane orchestra-toggle
sidebar=$(tmux show-options -gqv @orchestra_sidebar_pane_id)
[ -n "$sidebar" ] || { printf 'assertion failed: toggle stores the global sidebar pane id\n' >&2; exit 1; }
assert_eq "orchestra-tests|$window_id" "$(where_pane "$sidebar")" 'toggle opens the sidebar in the current window'
wait_eq 1 'the sidebar lists the Claude windows of both sessions and no plain window' sidebar_lists_both "$sidebar"
wait_eq 2 'the window with two Claude panes has a row for each' first_window_rows "$sidebar"

# A "|" or a newline in a pane's free text must not hide its row: clicks
# count every Claude pane, so a hidden row shifts every row below it.
sidebar_shows_piped_action() {
    case "$(tmux capture-pane -p -t "$1")" in *'piped ¦ wc'*) printf 1 ;; *) printf 0 ;; esac
}
tmux set-option -pq -t "$w1_first" @ab_agent_state running \; \
    set-option -pq -t "$w1_first" @ab_current_action 'Bash: piped | wc' \; \
    set-option -pq -t "$w1_first" @ab_last_cmd 'echo piped | wc
echo second line'
wait_eq 1 'a "|" in the current action is shown as "¦"' sidebar_shows_piped_action "$sidebar"
assert_eq 2 "$(first_window_rows "$sidebar")" 'a "|" or a newline in free text keeps the pane listed'
tmux set-option -pqu -t "$w1_first" @ab_agent_state \; \
    set-option -pqu -t "$w1_first" @ab_current_action \; \
    set-option -pqu -t "$w1_first" @ab_last_cmd

# Focusing a pane clears its own unread, not its neighbour's.
tmux set-option -pq -t "$w1_second" @ab_unread 1 \; set-option -pq -t "$w1_first" @ab_unread 1
tmux select-pane -t "$w1_second"
wait_eq '' 'focusing a pane clears its unread' popt "$w1_second" @ab_unread
assert_eq '1' "$(popt "$w1_first" @ab_unread)" 'focusing a pane leaves the other pane unread'
tmux set-option -pqu -t "$w1_first" @ab_unread

# Enter on a window in another session switches the client to it, and the
# client-session-changed / pane-focus-in hooks bring the sidebar along.
tmux set-option -gq @orchestra_selected_window "$other_claude_pane"
orchestra-select enter orchestra-tests
wait_eq "other|$other_claude" 'enter across sessions switches the client' where_client
wait_eq "other|$other_claude" 'the sidebar follows the client into the other session' where_pane "$sidebar"
assert_eq "$sidebar" "$(tmux show-options -gqv @orchestra_sidebar_pane_id)" 'the same sidebar pane moved'

# A click on the first block, from the sidebar now in "other", switches back.
orchestra-click 0 other
wait_eq "orchestra-tests|$window_id" 'a click across sessions switches the client' where_client
wait_eq "orchestra-tests|$window_id" 'the sidebar follows the client back' where_pane "$sidebar"

# Enter on the second Claude pane of a window, from another window whose
# last active pane was the first: select-window fires pane-focus-in for the
# first pane, and the follow hook must not select it back.
tmux select-pane -t "$w1_first"
tmux select-window -t "$window2_id"
wait_eq "orchestra-tests|$window2_id" 'the sidebar follows the client to a plain window' where_pane "$sidebar"
tmux set-option -gq @orchestra_selected_window "$w1_second"
orchestra-select enter orchestra-tests
wait_eq "orchestra-tests|$window_id" 'the sidebar follows the client to the picked pane' where_pane "$sidebar"
sleep 0.5
assert_eq "$window_id|$w1_second" "$(where_active)" 'enter from another window keeps the picked second pane'
# The picked pane is in the right-hand column of main-vertical; the sidebar
# still sits at the window's left edge, full height, not beside that pane.
assert_eq ok "$(sidebar_at_left_edge "$sidebar")" 'the sidebar follows to the left edge, full height, when a right-hand pane is picked'
assert_eq "32" "$(tmux display-message -p -t "$sidebar" '#{pane_width}')" 'the sidebar keeps its width at the left edge'

# A sidebar pane killed by hand: follow forgets it instead of failing.
tmux kill-pane -t "$sidebar"
orchestra-follow "$window_id" "$first_pane"
assert_eq '' "$(tmux show-options -gqv @orchestra_sidebar_pane_id)" 'follow clears a stale sidebar pane id'
assert_eq '' "$(tmux show-options -gqv @orchestra_sidebar_pid)" 'follow clears a stale sidebar pid'

# Toggling open from a right-hand pane still opens at the left edge, full height.
TMUX_PANE=$w1_second orchestra-toggle
sidebar=$(tmux show-options -gqv @orchestra_sidebar_pane_id)
assert_eq ok "$(sidebar_at_left_edge "$sidebar")" 'toggle from a right-hand pane opens the sidebar at the left edge, full height'
TMUX_PANE=$w1_second orchestra-toggle

# Entering a window takes the sidebar's columns from all its panes; leaving
# gives them to the left-most one. Without restoring the layout, each visit
# moved width from the right pane to the left. Two background windows with
# two side-by-side panes each: following in and out and toggling open and
# closed leave both panes' widths as they were.
pane_widths() {
    tmux list-panes -t "$1" -F '#{pane_id}:#{pane_width}' | tr '\n' ' '
}
drift_a=$(tmux new-window -d -t orchestra-tests -P -F '#{window_id}')
tmux split-window -d -h -t "$drift_a"
drift_b=$(tmux new-window -d -t orchestra-tests -P -F '#{window_id}')
tmux split-window -d -h -t "$drift_b"
drift_a_pane=$(tmux display-message -p -t "$drift_a" '#{pane_id}')
drift_b_pane=$(tmux display-message -p -t "$drift_b" '#{pane_id}')
widths_a=$(pane_widths "$drift_a")
widths_b=$(pane_widths "$drift_b")
TMUX_PANE=$drift_a_pane orchestra-toggle
sidebar=$(tmux show-options -gqv @orchestra_sidebar_pane_id)
assert_eq "orchestra-tests|$drift_a" "$(where_pane "$sidebar")" 'toggle opens the sidebar in a background window'
for _ in 1 2 3; do
    orchestra-follow "$drift_b" "$drift_b_pane"
    assert_eq "orchestra-tests|$drift_b" "$(where_pane "$sidebar")" 'follow moves the sidebar to the second window'
    assert_eq "$widths_a" "$(pane_widths "$drift_a")" 'the sidebar leaving a window restores its pane widths'
    orchestra-follow "$drift_a" "$drift_a_pane"
    assert_eq "$widths_b" "$(pane_widths "$drift_b")" 'the sidebar leaving the second window restores its pane widths'
done
TMUX_PANE=$drift_a_pane orchestra-toggle
assert_eq "$widths_a" "$(pane_widths "$drift_a")" 'closing the sidebar restores the pane widths'
for _ in 1 2 3; do
    TMUX_PANE=$drift_a_pane orchestra-toggle
    TMUX_PANE=$drift_a_pane orchestra-toggle
done
assert_eq "$widths_a" "$(pane_widths "$drift_a")" 'toggling the sidebar open and closed keeps the pane widths'
assert_eq '' "$(tmux show-options -wqv -t "$drift_a" @orchestra_layout_before)$(tmux show-options -wqv -t "$drift_a" @orchestra_layout_with)" 'closing the sidebar drops the saved layouts'

# A window resized while the sidebar is in it keeps the user's sizes: the
# saved layout no longer matches and is dropped, not applied.
TMUX_PANE=$drift_a_pane orchestra-toggle
sidebar=$(tmux show-options -gqv @orchestra_sidebar_pane_id)
tmux resize-pane -t "$drift_a_pane" -L 3
orchestra-follow "$drift_b" "$drift_b_pane"
assert_eq "orchestra-tests|$drift_b" "$(where_pane "$sidebar")" 'the sidebar left the resized window'
[ "$(pane_widths "$drift_a")" != "$widths_a" ] || { printf 'assertion failed: a window resized under the sidebar was reset to its old layout\n' >&2; exit 1; }
assert_eq '' "$(tmux show-options -wqv -t "$drift_a" @orchestra_layout_before)" 'a stale saved layout is dropped'

# The sidebar alone in its own window: following closes that window, and
# the next window still gets its layout back afterwards.
tmux break-pane -d -s "$sidebar"
widths_b=$(pane_widths "$drift_b")
orchestra-follow "$drift_b" "$drift_b_pane"
assert_eq "orchestra-tests|$drift_b" "$(where_pane "$sidebar")" 'follow moves the sidebar out of a window it was alone in'
TMUX_PANE=$drift_b_pane orchestra-toggle
assert_eq "$widths_b" "$(pane_widths "$drift_b")" 'the pane widths are restored after the sidebar came from a closed window'
tmux kill-window -t "$drift_a" \; kill-window -t "$drift_b"

# Migration: per-session sidebar options from earlier versions are dropped
# when the plugin loads.
tmux set-option -q -t other @ab_sidebar_pane_id '%9999' \; set-option -q -t other @ab_width 40 \; \
    set-option -q -t other @ab_selected_window "$other_claude"
"$REPO_DIR/orchestra.tmux"
assert_eq '' "$(tmux show-options -qv -t other @ab_sidebar_pane_id)$(tmux show-options -qv -t other @ab_width)$(tmux show-options -qv -t other @ab_selected_window)" 'loading the plugin clears old per-session sidebar options'

stop_client
tmux kill-session -t other

# A stale ORCHESTRA_WINDOW_ID must not override the pane the command is
# actually running in.
TMUX_PANE="$pane2_id" ORCHESTRA_WINDOW_ID="$window_id" orchestra set-state running --action 'pane wins'
assert_eq 'running' "$(tmux show-options -v -w -t "$window2_id" @ab_agent_state)" 'TMUX_PANE resolves the target window before stale ORCHESTRA_WINDOW_ID'
assert_eq 'pane wins' "$(tmux show-options -v -w -t "$window2_id" @ab_current_action)" 'state from the pane lands on the pane window'
assert_eq '' "$(tmux show-options -v -w -t "$window_id" @ab_agent_state 2>/dev/null || printf '')" 'stale ORCHESTRA_WINDOW_ID is ignored when TMUX_PANE is present'
orchestra clear-state --window "$window2_id"

# Clean up extra window.
tmux kill-window -t "$window2_id"
