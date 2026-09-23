#!/bin/sh
set -eu

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-cli.XXXXXX")
SOCKET=orchestra-test

cleanup() {
    PATH=$ORIGINAL_PATH tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
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
orchestra clear-state --window "$window_id"
assert_eq '' "$(tmux show-options -v -w -t "$window_id" @ab_agent_state 2>/dev/null || printf '')" 'clear-state clears agent state'

# The Claude pane detection format matches the version-named binary only.
start_claude "$window_id"
window1_claude_pane=$claude_pane
assert_eq '1' "$(tmux display-message -p -t "$window1_claude_pane" "$ORCHESTRA_CLAUDE_PANE")" 'a version-named pane counts as Claude'
assert_eq '0' "$(tmux display-message -p -t "$window_id.0" "$ORCHESTRA_CLAUDE_PANE")" 'a shell pane does not count as Claude'

# The sidebar lists only Claude windows, so clicks and the keyboard
# selection skip the others: a plain shell window, and one with a stale
# "running" state left behind by a Claude that exited without its Stop hook.
plain_id=$(tmux new-window -d -t orchestra-tests -P -F '#{window_id}')
window2_info=$(tmux new-window -t orchestra-tests -P -F '#{window_id}|#{pane_id}')
window2_id=${window2_info%%|*}
pane2_id=${window2_info#*|}
start_claude "$window2_id"
stale_id=$(tmux new-window -d -t orchestra-tests -P -F '#{window_id}')
orchestra set-state running --action 'Bash: ls' --window "$stale_id"

# Mouse click: orchestra-click <y> <session> selects the listed window at
# block y/3.
tmux select-window -t "$window_id"
active_before=$(tmux display-message -p -t orchestra-tests '#{window_id}')
assert_eq "$window_id" "$active_before" 'window 1 is active before click'
# Y=3 → block 1 → second Claude window, skipping the plain window.
orchestra-click 3 orchestra-tests
active_after=$(tmux display-message -p -t orchestra-tests '#{window_id}')
assert_eq "$window2_id" "$active_after" 'orchestra-click skips non-Claude windows'
# Y=0 → block 0 → first window.
orchestra-click 0 orchestra-tests
active_back=$(tmux display-message -p -t orchestra-tests '#{window_id}')
assert_eq "$window_id" "$active_back" 'orchestra-click y=0 selects first window'
# Y=6 → block 2 → only the stale and plain windows remain, neither listed.
orchestra-click 6 orchestra-tests
active_unchanged=$(tmux display-message -p -t orchestra-tests '#{window_id}')
assert_eq "$window_id" "$active_unchanged" 'orchestra-click past the last Claude window is a no-op'
orchestra-click 999 orchestra-tests
active_unchanged=$(tmux display-message -p -t orchestra-tests '#{window_id}')
assert_eq "$window_id" "$active_unchanged" 'orchestra-click out-of-range is a no-op'

# Keyboard selection: orchestra-select moves @ab_selected_window across the
# Claude windows without switching windows, clamps at both ends, and enter
# selects it.
window3_id=$(tmux new-window -d -t orchestra-tests -P -F '#{window_id}')
start_claude "$window3_id"
tmux select-window -t "$window_id"
orchestra-select up orchestra-tests
assert_eq "$window_id" "$(tmux show-options -v -t orchestra-tests @ab_selected_window)" 'selection starts on the active window and clamps at the top'
orchestra-select down orchestra-tests
assert_eq "$window2_id" "$(tmux show-options -v -t orchestra-tests @ab_selected_window)" 'selection skips the plain window'
orchestra-select down orchestra-tests
assert_eq "$window3_id" "$(tmux show-options -v -t orchestra-tests @ab_selected_window)" 'selection skips the stale-state window'
orchestra-select down orchestra-tests
assert_eq "$window3_id" "$(tmux show-options -v -t orchestra-tests @ab_selected_window)" 'selection clamps at the bottom'
assert_eq "$window_id" "$(tmux display-message -p -t orchestra-tests '#{window_id}')" 'moving the selection does not switch windows'
orchestra-select enter orchestra-tests
assert_eq "$window3_id" "$(tmux display-message -p -t orchestra-tests '#{window_id}')" 'enter selects the highlighted window'
assert_eq '' "$(tmux show-options -v -t orchestra-tests @ab_selected_window 2>/dev/null || printf '')" 'enter clears the selection'
tmux set-option -q -t orchestra-tests @ab_selected_window '@999'
orchestra-select up orchestra-tests
assert_eq "$window2_id" "$(tmux show-options -v -t orchestra-tests @ab_selected_window)" 'a stale selection falls back to the active window'
orchestra-select reset orchestra-tests
assert_eq '' "$(tmux show-options -v -t orchestra-tests @ab_selected_window 2>/dev/null || printf '')" 'reset clears the selection'
# From a window without Claude, the selection falls back to the first
# Claude window.
tmux select-window -t "$plain_id"
orchestra-select down orchestra-tests
assert_eq "$window2_id" "$(tmux show-options -v -t orchestra-tests @ab_selected_window)" 'a non-Claude active window falls back to the first Claude window'
orchestra-select reset orchestra-tests
tmux select-window -t "$plain_id"
orchestra-select enter orchestra-tests
assert_eq "$window_id" "$(tmux display-message -p -t orchestra-tests '#{window_id}')" 'enter from a non-Claude window selects the first Claude window'
tmux kill-window -t "$window3_id"
tmux kill-window -t "$plain_id"
tmux kill-window -t "$stale_id"
tmux select-window -t "$window_id"

# A stale ORCHESTRA_WINDOW_ID must not override the pane the command is
# actually running in.
TMUX_PANE="$pane2_id" ORCHESTRA_WINDOW_ID="$window_id" orchestra set-state running --action 'pane wins'
assert_eq 'running' "$(tmux show-options -v -w -t "$window2_id" @ab_agent_state)" 'TMUX_PANE resolves the target window before stale ORCHESTRA_WINDOW_ID'
assert_eq 'pane wins' "$(tmux show-options -v -w -t "$window2_id" @ab_current_action)" 'state from the pane lands on the pane window'
assert_eq '' "$(tmux show-options -v -w -t "$window_id" @ab_agent_state 2>/dev/null || printf '')" 'stale ORCHESTRA_WINDOW_ID is ignored when TMUX_PANE is present'
orchestra clear-state --window "$window2_id"

# Clean up extra window.
tmux kill-window -t "$window2_id"
