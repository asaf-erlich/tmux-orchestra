#!/bin/sh
# End-to-end test of the orphaned-session list, on a private tmux server.
#
# A stub `claude` on PATH prints canned `agents --json --all` and records
# `--resume <id>` instead of running anything. The real renderer runs in the
# sidebar pane (bin/orchestra-toggle) and starts the real bin/orchestra-bg-refresh
# itself; the frame is read with capture-pane and keys are typed into the
# sidebar pane. A headless client (as in tests/test_cli.sh) answers
# confirm-before. Nothing here touches the default tmux server.
set -eu

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-e2e.XXXXXX")
# Physical path: pane_current_path is the resolved one (/var -> /private/var).
TMP_DIR=$(CDPATH='' cd -P -- "$TMP_DIR" && pwd -P)
SOCKET=orchestra-e2e-$$

client_pid=''
cleanup() {
    PATH=$ORIGINAL_PATH tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    if [ -n "$client_pid" ]; then
        kill "$client_pid" >/dev/null 2>&1 || true
    fi
    for pidfile in "$TMP_DIR"/*.pid; do
        [ -s "$pidfile" ] || continue
        kill "$(cat "$pidfile")" >/dev/null 2>&1 || true
    done
    rm -rf "$TMP_DIR"
    rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"
}
trap cleanup EXIT
trap 'exit 1' INT TERM PIPE

ORIGINAL_PATH=$PATH
command -v jq >/dev/null 2>&1 || { printf 'test_orphans_e2e: jq is required\n' >&2; exit 1; }

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home" "$TMP_DIR/projA" "$TMP_DIR/projB" "$TMP_DIR/projC" \
    "$TMP_DIR/projD" "$TMP_DIR/projE" "$TMP_DIR/projF"
cat >"$TMP_DIR/bin/tmux" <<EOF
#!/bin/sh
exec $(command -v tmux) -L "$SOCKET" "\$@"
EOF
chmod +x "$TMP_DIR/bin/tmux"

# The stub: `agents --json [--all]` prints $AGENTS_JSON and counts the call;
# `--resume ID` records its argv.
cat >"$TMP_DIR/bin/claude" <<'EOF'
#!/bin/sh
case "$1" in
    agents)
        printf x >>"$E2E_DIR/agents-calls"
        cat "$E2E_DIR/agents.json"
        ;;
    --resume)
        printf '%s\n' "$*" >>"$E2E_DIR/resume.log"
        ;;
esac
EOF
chmod +x "$TMP_DIR/bin/claude"
: >"$TMP_DIR/resume.log"
: >"$TMP_DIR/agents-calls"

# Fake still-running Claude processes: copies of sleep with "claude" in the
# name (what bin/orchestra-orphan-resume checks), outside every tmux pane.
# macOS kills a copied platform binary unless it is re-signed.
cp "$(command -v sleep)" "$TMP_DIR/claude-live"
if command -v codesign >/dev/null 2>&1; then
    codesign -f -s - "$TMP_DIR/claude-live" >/dev/null 2>&1 || true
fi
"$TMP_DIR/claude-live" 600 &
live_pid=$!
echo "$live_pid" >"$TMP_DIR/live.pid"
"$TMP_DIR/claude-live" 600 &
bystander_pid=$!
echo "$bystander_pid" >"$TMP_DIR/bystander.pid"
sleep 0 &
dead_pid=$!
wait "$dead_pid"

HOME=$TMP_DIR/home
E2E_DIR=$TMP_DIR
export HOME E2E_DIR
PATH=$TMP_DIR/bin:$REPO_DIR/bin:$PATH
export PATH
SHELL=/bin/sh
export SHELL

# Usage: write_agents
# The canned `claude agents --json --all` output; newest session first by
# startedAt (ms).
write_agents() {
    {
        cat <<EOF
[
 {"kind":"background","id":"bgA","sessionId":"sessA","state":"done","startedAt":9000,"cwd":"$TMP_DIR/projA","name":"alpha"},
 {"kind":"background","id":"bgB","sessionId":"sessB","state":"done","startedAt":8000,"cwd":"$TMP_DIR/projB","name":"beta"},
 {"kind":"background","id":"bgC","sessionId":"sessC","state":"failed","startedAt":7000,"cwd":"$TMP_DIR/projC","name":"gamma"},
 {"kind":"background","id":"bgHome","sessionId":"sessHome","state":"done","startedAt":6000,"cwd":"$HOME","name":"homejob"},
 {"kind":"interactive","id":"iLive","sessionId":"sessLive","pid":$live_pid,"startedAt":5000,"cwd":"$TMP_DIR/projD","name":"livesess"},
 {"kind":"interactive","id":"iDead","sessionId":"sessDead","pid":$dead_pid,"startedAt":4000,"cwd":"$TMP_DIR/projE","name":"deadsess"},
 {"kind":"background","id":"bgHeld","sessionId":"sessHeld","state":"done","startedAt":3000,"cwd":"$TMP_DIR/projF","name":"heldjob"},
 {"kind":"background","id":"bgAtt","sessionId":"sessAtt","state":"done","startedAt":2500,"cwd":"$TMP_DIR/projF","name":"attjob"},
 {"kind":"background","id":"bgRun","sessionId":"sessRun","state":"running","status":"busy","startedAt":2000,"cwd":"$TMP_DIR/projF","name":"runner"}
EOF
        printf ']\n'
    } >"$TMP_DIR/agents.json.new"
    \mv -f "$TMP_DIR/agents.json.new" "$TMP_DIR/agents.json"
}
write_agents

assert_eq() {
    if [ "$1" != "$2" ]; then
        printf 'assertion failed: %s\nexpected: %s\nactual:   %s\n' "$3" "$1" "$2" >&2
        printf -- '--- frame ---\n%s\n' "$(frame 2>/dev/null || true)" >&2
        tmux list-panes -a -F '#{pane_id} #{window_name} #{pane_current_command} #{pane_dead} #{pane_width}x#{pane_height}' >&2 || true
        exit 1
    fi
}

# Usage: wait_eq EXPECTED MESSAGE COMMAND...   (polls up to 8 s)
wait_eq() {
    wait_expected=$1
    wait_message=$2
    shift 2
    wait_tries=0
    while :; do
        wait_actual=$("$@" 2>/dev/null || true)
        [ "$wait_actual" != "$wait_expected" ] || return 0
        wait_tries=$((wait_tries + 1))
        [ "$wait_tries" -lt 80 ] || assert_eq "$wait_expected" "$wait_actual" "$wait_message"
        sleep 0.1
    done
}

opt() { tmux show-options -gqv "$1"; }
# The renderer draws from the top without clearing first, so a capture can
# catch half a frame: take the capture two times in a row alike.
frame() {
    frame_prev=$(tmux capture-pane -p -t "$sidebar")
    frame_tries=0
    while :; do
        sleep 0.05
        frame_now=$(tmux capture-pane -p -t "$sidebar")
        [ "$frame_now" != "$frame_prev" ] || break
        frame_prev=$frame_now
        frame_tries=$((frame_tries + 1))
        [ "$frame_tries" -lt 40 ] || break
    done
    printf '%s\n' "$frame_now"
}
# Space separated ids of @orchestra_orphan_agents, in order.
orphan_ids() {
    opt @orchestra_orphan_agents | tr '|' '\n' | cut -d';' -f1 | tr '\n' ' ' | sed 's/ $//'
}
# 0-based frame line of the first line containing TEXT, else empty.
row_of() {
    frame | grep -nF -- "$1" | head -n 1 | cut -d: -f1 | awk '{ print $1 - 1 }'
}
section_shown() { frame_has '── orphaned'; }
frame_has() { frame | grep -qF -- "$1" && printf 1 || printf 0; }
resume_log() { cat "$TMP_DIR/resume.log"; }
resume_count() { wc -l <"$TMP_DIR/resume.log" | tr -d ' '; }
orphan_count() { opt @orchestra_orphan_agents | tr '|' '\n' | grep -c . || true; }
agents_calls() { wc -c <"$TMP_DIR/agents-calls" | tr -d ' '; }
window_names() { tmux list-windows -F '#{window_name}' | sort | tr '\n' ' ' | sed 's/ $//'; }
selected() { opt @orchestra_selected_window; }
alive() { kill -0 "$1" 2>/dev/null && printf 1 || printf 0; }

# Usage: wait_refreshes N   -- until the sidebar's refresh job ran N more times.
wait_refreshes() {
    target=$(($(agents_calls) + $1))
    wait_tries=0
    while [ "$(agents_calls)" -lt "$target" ]; do
        wait_tries=$((wait_tries + 1))
        [ "$wait_tries" -lt 120 ] || assert_eq "$target" "$(agents_calls)" 'the refresh job keeps running'
        sleep 0.1
    done
    # Let the option writes of the last run land.
    sleep 0.3
}

# Usage: move_to ID
# Selects orphan row ID with j: the list is the background sessions, then the
# orphans (no Claude panes exist here), and an unset selection is the first.
move_to() {
    tmux set-option -gqu @orchestra_selected_window
    nbg=$(opt @orchestra_bg_agents | tr '|' '\n' | grep -c . || true)
    pos=0
    for id in $(orphan_ids); do
        [ "$id" != "$1" ] || break
        pos=$((pos + 1))
    done
    idx=$((nbg + pos))
    [ "$idx" -eq 0 ] || tmux send-keys -t "$sidebar" -l "$(printf '%*s' "$idx" '' | tr ' ' j)"
    wait_eq "orphan:$1" "keyboard selection reaches $1" selected
}

# ---- server, session, headless client --------------------------------------
tmux -f /dev/null new-session -d -x 120 -y 80 -s e2e -n main -c "$TMP_DIR"
tmux set-option -g default-shell /bin/sh
window_id=$(tmux display-message -p -t e2e:main '#{window_id}')
first_pane=$(tmux display-message -p -t "$window_id" '#{pane_id}')

# A pane that holds session sessHeld, and a window attached to bgAtt.
tmux set-option -pq -t "$first_pane" @ab_session_id sessHeld
tmux new-window -d -t e2e: -n attached "sleep 600"
tmux set-option -wq -t e2e:attached @orchestra_bg_id bgAtt

# Shell windows for the resume target rule: projA has exactly one (same cwd).
tmux new-window -d -t e2e: -n projA -c "$TMP_DIR/projA"

{ sh -c 'echo "$$" >"$1"; exec sleep 600' sh "$TMP_DIR/client-stdin.pid"; } |
    script -q /dev/null sh -c "stty rows 80 cols 120; exec tmux -L '$SOCKET' attach -t e2e" >/dev/null 2>&1 &
client_pid=$!
client_attached() { tmux list-clients -F '#{client_session}'; }
wait_eq e2e 'a headless client attaches' client_attached
client=$(tmux list-clients -F '#{client_name}' | head -n 1)

# Start the sidebar; its renderer runs the refresh job once a second.
tmux set-option -gq @orchestra_bg_interval 1
TMUX_PANE=$first_pane orchestra-toggle
sidebar=$(opt @orchestra_sidebar_pane_id)
[ -n "$sidebar" ] || { printf 'sidebar did not open\n' >&2; exit 1; }
session_name=e2e

# ---- (1) completed background sessions under "orphaned", newest first -------
wait_eq 'sessA sessB sessC sessHome sessLive sessDead' \
    'orphans: done and failed background, interactive; not held, attached or running' orphan_ids
assert_eq 1 "$(frame_has '── orphaned')" 'the orphaned separator is drawn'
done_rows=$(frame | grep -cF '✓ done' || true)
assert_eq 4 "$done_rows" 'four completed sessions show "✓ done"'
prev=-1
for title in projA projB projC homejob projD projE; do
    row=$(row_of "$title")
    if [ -z "$row" ] || [ "$row" -le "$prev" ]; then
        assert_eq "row of $title after $prev" "$row" 'orphan rows are newest first'
    fi
    prev=$row
done

# ---- (8) a running background session only in the background section -------
assert_eq 'bgRun' "$(opt @orchestra_bg_agents | cut -d';' -f1)" 'the running session is in the background list'
assert_eq 1 "$(frame_has '── background')" 'the background separator is drawn'
bg_row=$(row_of '── background')
orph_row=$(row_of '── orphaned')
runner_row=$(row_of runner)
if [ "$bg_row" -ge "$runner_row" ] || [ "$runner_row" -ge "$orph_row" ]; then
    assert_eq 'runner between the separators' "$bg_row/$runner_row/$orph_row" 'the running session is in the background section'
fi
case " $(orphan_ids) " in *' sessRun '*) assert_eq absent present 'running session is not an orphan' ;; esac

# ---- (4) a $HOME session is titled by its session name -----------------------
assert_eq 1 "$(frame_has homejob)" "a \$HOME session is titled by its name"

# ---- (7) a live session outside every pane ------------------------------------
assert_eq 1 "$(frame_has "● pid $live_pid live elsewhere")" 'a live session shows its pid'
assert_eq 1 "$(frame_has '↺ resume')" 'a dead interactive session shows "↺ resume"'

# ---- (2) Enter resumes in the one matching shell window ---------------------
windows_before=$(window_names)
move_to sessA
tmux send-keys -t "$sidebar" Enter
wait_eq '--resume sessA' 'Enter types "claude --resume" into the matching shell' resume_log
assert_eq "$windows_before" "$(window_names)" 'no new window when exactly one shell matches'
assert_eq projA "$(tmux display-message -p -t e2e '#{window_name}')" 'the matching window is shown'

# ... else a new window named after the directory.
move_to sessB
tmux send-keys -t "$sidebar" Enter
wait_eq '--resume sessA
--resume sessB' 'Enter with no matching shell opens a window that resumes' resume_log
case " $(window_names) " in *' projB '*) ;; *) assert_eq 'a window named projB' "$(window_names)" 'new window is named after the cwd' ;; esac

# ---- (3) a click does the same -----------------------------------------------
row=$(row_of projC)
[ -n "$row" ] || assert_eq 'a projC row' none 'projC is listed'
orchestra-click "$((row + 1))" "$session_name"
wait_eq '--resume sessA
--resume sessB
--resume sessC' 'a click on a done row resumes it' resume_log
case " $(window_names) " in *' projC '*) ;; *) assert_eq 'a window named projC' "$(window_names)" 'click opens a window named after the cwd' ;; esac

# ---- (4) resuming the $HOME session names the window after the session -----
move_to sessHome
tmux send-keys -t "$sidebar" Enter
home_window() { tmux list-windows -F '#{window_name}' | grep -qx homejob && printf 1; }
wait_eq 1 "the \$HOME session resumes in a window named after it" home_window
wait_eq '--resume sessA
--resume sessB
--resume sessC
--resume sessHome' "the \$HOME session is resumed" resume_log
# A completed background session stays in `claude agents --all` after it is
# resumed, so resuming one hides it (dismisses it); the others stay listed.
wait_eq 'sessLive sessDead' 'resumed completed sessions leave the list' orphan_ids
assert_eq 'sessA sessB sessC sessHome' "$(opt @orchestra_orphan_dismissed)" 'resumed completed sessions are remembered as dismissed'

# ---- (7) live session: confirm-before ---------------------------------------
# Enter asks first; n leaves the process alone.
move_to sessLive
tmux send-keys -t "$sidebar" Enter
sleep 0.7
tmux send-keys -K -c "$client" n
sleep 1
assert_eq 1 "$(alive "$live_pid")" 'n leaves the live process alone'
assert_eq '--resume sessA
--resume sessB
--resume sessC
--resume sessHome' "$(resume_log)" 'n does not resume'
# Enter then y kills only that pid and resumes.
move_to sessLive
tmux send-keys -t "$sidebar" Enter
sleep 0.7
tmux send-keys -K -c "$client" y
wait_eq 0 'y kills the live process' alive "$live_pid"
wait_eq 5 'y resumes the session' resume_count
assert_eq '--resume sessLive' "$(resume_log | tail -n 1)" 'y resumes the live session'
assert_eq 1 "$(alive "$bystander_pid")" 'y kills only that pid'

# ---- (5) x dismisses a row for good ------------------------------------------
move_to sessDead
tmux send-keys -t "$sidebar" -l x
wait_eq 'sessLive' 'x removes the row at once' orphan_ids
assert_eq 'sessA sessB sessC sessHome sessDead' "$(opt @orchestra_orphan_dismissed)" 'the id is remembered as dismissed'
wait_refreshes 2
case " $(orphan_ids) " in *' sessDead '*) assert_eq 'sessDead gone' "$(orphan_ids)" 'the dismissed row stays gone after a refresh' ;; esac
assert_eq 0 "$(frame_has projE)" 'the dismissed row is not drawn'

# ---- (6) the cap and the off switch -------------------------------------------
# Forget the dismissals (resumed and x'd) to get the full list back.
tmux set-option -gqu @orchestra_orphan_dismissed
wait_eq 6 'clearing the dismissals brings every row back' orphan_count
tmux set-option -gq @orchestra_orphans_max 2
wait_eq 2 '@orchestra_orphans_max caps the list' orphan_count
tmux set-option -gq @orchestra_orphans_max 10
wait_eq 6 'raising the cap brings the rows back' orphan_count
tmux set-option -gq @orchestra_orphans off
wait_eq '' '@orchestra_orphans off clears the list' opt @orchestra_orphan_agents
wait_eq 0 '@orchestra_orphans off hides the section' section_shown
assert_eq 1 "$(frame_has '── background')" 'the background section stays with orphans off'
tmux set-option -gqu @orchestra_orphans

printf 'test_orphans_e2e: all passed\n'
