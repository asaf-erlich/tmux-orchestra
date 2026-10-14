#!/bin/sh
# End-to-end test of the background health check (`orchestra-claude-hook
# reconcile`), on a private tmux server, with the real `ps` and real processes.
#
# "Claude" is a copy of the shell named `claude` (so pane_current_command is
# `claude`, what ORCHESTRA_CLAUDE_PANE matches), running in tmux panes. Each
# gets a session file (private $HOME) saying idle for an hour, a transcript
# with no finished notification, and the pane options the real Stop hook
# writes: the test pipes a realistic Stop payload (with a background_tasks
# list) into `orchestra-claude-hook stop`. One of them has a real `sh -c
# 'sleep 600'` child, a descendant of its pid in the real process table.
# Timings are shortened with ORCHESTRA_BG_GRACE / ORCHESTRA_BG_FRESH, which
# are read by the hook, whether run by hand or by the real sidebar renderer's
# refresh job (bin/orchestra-toggle).
#
# The `ps` on PATH is a pass-through that only counts its calls.
# Nothing here touches the default tmux server.
set -eu

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-bgalive.XXXXXX")
TMP_DIR=$(CDPATH='' cd -P -- "$TMP_DIR" && pwd -P)
SOCKET=orchestra-bgalive-$$
ORIGINAL_PATH=$PATH

client_pid=''
cleanup() {
    PATH=$ORIGINAL_PATH tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    if [ -n "$client_pid" ]; then
        kill "$client_pid" >/dev/null 2>&1 || true
    fi
    for pidfile in "$TMP_DIR"/*.pid "$TMP_DIR"/*.child; do
        [ -s "$pidfile" ] || continue
        pid=$(cat "$pidfile")
        for kid in $(pgrep -P "$pid" 2>/dev/null); do
            kill "$kid" >/dev/null 2>&1 || true
        done
        kill "$pid" >/dev/null 2>&1 || true
    done
    rm -rf "$TMP_DIR"
    rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"
}
trap cleanup EXIT
trap 'exit 1' INT TERM PIPE

command -v jq >/dev/null 2>&1 || { printf 'test_bgalive_e2e: jq is required\n' >&2; exit 1; }
command -v script >/dev/null 2>&1 || { printf 'test_bgalive_e2e: script(1) is required\n' >&2; exit 1; }

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home/.claude/sessions" "$TMP_DIR/home/.claude/projects/proj" "$TMP_DIR/tasks/proj"
cat >"$TMP_DIR/bin/tmux" <<EOF
#!/bin/sh
exec $(command -v tmux) -L "$SOCKET" "\$@"
EOF
# A counting pass-through: the real ps still runs. While $TMP_DIR/ps-etime
# exists, its content replaces the etime column of the health check's call, so
# the test controls how old the real child looks.
REAL_PS=$(command -v ps)
cat >"$TMP_DIR/bin/ps" <<EOF
#!/bin/sh
printf x >>"$TMP_DIR/ps-calls"
E=\$(cat "$TMP_DIR/ps-etime" 2>/dev/null)
case "\$*" in
    *etime=*) [ -n "\$E" ] && { $REAL_PS "\$@" | sed -E "s/^( *[0-9]+ +[0-9]+ +)[^ ]+/\1\$E/"; exit 0; } ;;
esac
exec $REAL_PS "\$@"
EOF
chmod +x "$TMP_DIR/bin/tmux" "$TMP_DIR/bin/ps"
: >"$TMP_DIR/ps-calls"

# The fake Claude: a copy of a shell, so its process is named `claude`
# (macOS names a copy of /bin/sh "bash", so dash is preferred). macOS kills a
# copied platform binary unless it is re-signed.
fake_shell=/bin/sh
[ ! -x /bin/dash ] || fake_shell=/bin/dash
cp "$fake_shell" "$TMP_DIR/claude"
if command -v codesign >/dev/null 2>&1; then
    codesign -f -s - "$TMP_DIR/claude" >/dev/null 2>&1 || true
fi

HOME=$TMP_DIR/home
ORCHESTRA_TASKS_ROOT=$TMP_DIR/tasks
ORCHESTRA_BG_GRACE=6
ORCHESTRA_BG_FRESH=3
SHELL=/bin/sh
PATH=$TMP_DIR/bin:$REPO_DIR/bin:$PATH
export HOME ORCHESTRA_TASKS_ROOT ORCHESTRA_BG_GRACE ORCHESTRA_BG_FRESH SHELL PATH
unset CLAUDE_CONFIG_DIR TMUX TMUX_PANE || true

assert_eq() {
    if [ "$1" != "$2" ]; then
        printf 'assertion failed: %s\nexpected: %s\nactual:   %s\n' "$3" "$1" "$2" >&2
        printf -- '--- frame ---\n%s\n' "$(frame 2>/dev/null || true)" >&2
        exit 1
    fi
}

# Usage: wait_eq EXPECTED MESSAGE COMMAND...   (polls up to 25 s)
wait_eq() {
    wait_expected=$1
    wait_message=$2
    shift 2
    wait_tries=0
    while :; do
        wait_actual=$("$@" 2>/dev/null || true)
        [ "$wait_actual" != "$wait_expected" ] || return 0
        wait_tries=$((wait_tries + 1))
        [ "$wait_tries" -lt 250 ] || assert_eq "$wait_expected" "$wait_actual" "$wait_message"
        sleep 0.1
    done
}

opt() { tmux show-options -gqv "$1"; }
# Usage: popt NAME OPTION   -- a pane option of scenario NAME's pane.
popt() { tmux show-options -pqv -t "$(cat "$TMP_DIR/$1.pane")" "$2"; }
state_of() { popt "$1" @ab_agent_state; }
action_of() { popt "$1" @ab_current_action; }
alive_at_of() { popt "$1" @ab_bg_alive_at; }
ps_calls() { wc -c <"$TMP_DIR/ps-calls" | tr -d ' '; }
now() { date +%s; }
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
# The activity row of scenario NAME's block: the line after its title border.
row_of() { frame | grep -A1 -F "e2e:$1 " | tail -n 1; }
# The same row with its escape sequences: the colour of the text on it.
ansi_row_of() {
    tmux capture-pane -p -e -t "$sidebar" | grep -A1 -F "e2e:$1" | tail -n 1
}
reconcile() { orchestra-claude-hook reconcile </dev/null; }
# Usage: mark_old FILE  -- a task output file nothing wrote to for years.
mark_old() { touch -t 202001010000 "$1"; }

file_ready() { [ -s "$1" ] && printf 1; }

# Usage: start_fake NAME SESSION_ID TASK_ID DESCRIPTION [child]
# Starts the fake Claude of scenario NAME in its own window (the first one,
# "focus", is the session's first window), records its session file and
# transcript, and pipes a realistic Stop payload through the real hook.
# With "child", it runs a real `sh -c 'sleep 600'` child.
start_fake() {
    sf_name=$1 sf_sid=$2 sf_task=$3 sf_desc=$4
    {
        printf 'echo $$ >"%s/%s.pid"\n' "$TMP_DIR" "$sf_name"
        if [ "${5:-}" = child ]; then
            printf 'sh -c "echo \\$\\$ >%s/%s.child; sleep 600; :" &\n' "$TMP_DIR" "$sf_name"
        fi
        printf 'while :; do sleep 1; done\n'
    } >"$TMP_DIR/$sf_name.sh"
    if [ "$sf_name" = focus ]; then
        tmux -f /dev/null new-session -d -x 120 -y 80 -s e2e -n "$sf_name" -c "$TMP_DIR" "$TMP_DIR/claude $TMP_DIR/$sf_name.sh"
        tmux set-option -g default-shell /bin/sh
    else
        tmux new-window -d -t e2e: -n "$sf_name" -c "$TMP_DIR" "$TMP_DIR/claude $TMP_DIR/$sf_name.sh"
    fi
    tmux display-message -p -t "e2e:$sf_name" '#{pane_id}' >"$TMP_DIR/$sf_name.pane"
    wait_eq 1 "$sf_name fake claude starts" file_ready "$TMP_DIR/$sf_name.pid"
    sf_pid=$(cat "$TMP_DIR/$sf_name.pid")
    old_ms=$((($(now) - 3600) * 1000))
    printf '{"pid":%s,"sessionId":"%s","status":"idle","statusUpdatedAt":%s}\n' "$sf_pid" "$sf_sid" "$old_ms" \
        >"$HOME/.claude/sessions/$sf_pid.json"
    printf '{"type":"user","message":"hi"}\n{"type":"assistant","message":"started a background task"}\n' \
        >"$HOME/.claude/projects/proj/$sf_sid.jsonl"
    printf '{"background_tasks":[{"id":"%s","type":"local_bash","status":"running","description":"%s"}],"session_id":"%s"}' \
        "$sf_task" "$sf_desc" "$sf_sid" |
        TMUX_PANE=$(cat "$TMP_DIR/$sf_name.pane") orchestra-claude-hook stop
}

# ---- setup: five fake Claude panes ----------------------------------------------
mkdir -p "$TMP_DIR/tasks/proj/sidAlive/tasks" "$TMP_DIR/tasks/proj/sidStopped/tasks" \
    "$TMP_DIR/tasks/proj/sidFresh/tasks" "$TMP_DIR/tasks/proj/sidFocus/tasks" "$TMP_DIR/tasks/proj/sidUnknown/tasks"
for f in sidAlive/tasks/bgA sidStopped/tasks/bgS sidFocus/tasks/bgP; do
    : >"$TMP_DIR/tasks/proj/$f.output"
    mark_old "$TMP_DIR/tasks/proj/$f.output"
done
: >"$TMP_DIR/tasks/proj/sidFresh/tasks/bgF.output"

start_fake focus sidFocus bgP 'sleep 900'
start_fake alive sidAlive bgA 'sleep 900' child
start_fake stopped sidStopped bgS 'sleep 900'
start_fake fresh sidFresh bgF 'sleep 900'
start_fake unknown sidUnknown bgU 'watch live updates'
wait_eq 1 'the alive child shell starts' file_ready "$TMP_DIR/alive.child"
t_stop=$(now)

# A headless client shows the "focus" window, so its pane is the one you are
# looking at.
{ sh -c 'echo "$$" >"$1"; exec sleep 600' sh "$TMP_DIR/client-stdin.pid"; } |
    script -q /dev/null sh -c "stty rows 80 cols 120; exec tmux -L '$SOCKET' attach -t e2e" >/dev/null 2>&1 &
client_pid=$!
client_attached() { tmux list-clients -F '#{client_session}'; }
wait_eq e2e 'a headless client attaches' client_attached
tmux select-window -t e2e:focus

# ---- Stop wrote what the health check reads ----------------------------------------
assert_eq background "$(state_of alive)" 'Stop with a running task marks the pane background'
assert_eq '1 background: sleep 900' "$(action_of alive)" 'Stop writes "N background: cmd"'
assert_eq bgA "$(popt alive @ab_bg_tasks)" 'Stop records the task ids'
assert_eq 1 "$(( $(alive_at_of alive) >= t_stop - 5 ))" 'Stop stamps @ab_bg_alive_at'
assert_eq 1 "$(tmux display-message -p -t "$(cat "$TMP_DIR/focus.pane")" '#{pane_current_command}' | grep -c '^claude$')" 'the fake process is named claude'

# ---- (g) one ps per reconcile pass, however many background panes ------------------
# Within the grace: nothing ends; alive work is stamped; unknown is marked.
sleep 1.1
t_pass1=$(now)
touch "$TMP_DIR/tasks/proj/sidFresh/tasks/bgF.output"
before=$(ps_calls)
reconcile
assert_eq 1 "$(($(ps_calls) - before))" 'one ps for a pass over five background panes'
for name in focus alive stopped fresh unknown; do
    assert_eq background "$(state_of $name)" "$name is still background within the grace"
done
# (b) a real descendant `sh -c` keeps it alive and advances @ab_bg_alive_at.
assert_eq 1 "$(( $(alive_at_of alive) >= t_pass1 ))" 'a live sh -c child advances @ab_bg_alive_at'
assert_eq '1 background: sleep 900' "$(action_of alive)" 'live work keeps the plain row'
# (e) a fresh output file keeps it alive with no process.
assert_eq 1 "$(( $(alive_at_of fresh) >= t_pass1 ))" 'a fresh task output file advances @ab_bg_alive_at'
assert_eq '1 background: sleep 900' "$(action_of fresh)" 'fresh output keeps the plain row'
# (d) a task with neither a process nor an output file is unknown.
assert_eq '1 background? watch live updates' "$(action_of unknown)" 'unknown work reads "background?"'
# Stopped, within the grace: not ended yet, @ab_bg_alive_at unchanged.
assert_eq 1 "$(( $(alive_at_of stopped) <= t_pass1 ))" 'stopped work is not stamped alive'

# ---- the shipped defaults are far longer than the test's grace --------------------
# Wait out the shortened grace, then run once with the defaults (600 s grace):
# nothing ends.
while [ "$(now)" -lt $((t_stop + ORCHESTRA_BG_GRACE + 1)) ]; do sleep 0.2; done
touch "$TMP_DIR/tasks/proj/sidFresh/tasks/bgF.output"
env -u ORCHESTRA_BG_GRACE -u ORCHESTRA_BG_FRESH orchestra-claude-hook reconcile </dev/null
assert_eq background "$(state_of stopped)" 'with the default 600 s grace a stopped pane has not ended after 7 s'
assert_eq background "$(state_of focus)" 'with the default grace the focused pane has not ended either'

# ---- (c)/(f) stopped work ends after the grace --------------------------------------
# alive and fresh stay background; stopped and focus end (focus without unread).
tmux select-window -t e2e:focus
tmux select-pane -t "$(cat "$TMP_DIR/focus.pane")"
t_pass2=$(now)
touch "$TMP_DIR/tasks/proj/sidFresh/tasks/bgF.output"
reconcile
assert_eq '' "$(state_of stopped)" 'stopped work ends once the grace has passed'
assert_eq '' "$(popt stopped @ab_bg_tasks)" 'the ended pane forgets its tasks'
assert_eq '' "$(alive_at_of stopped)" 'the ended pane forgets @ab_bg_alive_at'
assert_eq 1 "$(popt stopped @ab_unread)" 'an unfocused pane that ends is unread'
assert_eq 1 "$([ -n "$(popt stopped @ab_finished_at)" ] && printf 1)" 'the ended pane has a finish time'
assert_eq '' "$(state_of focus)" '(f) the focused pane ends too'
assert_eq '' "$(popt focus @ab_unread)" '(f) a focused pane that ends is not unread'
# Past the grace, live and fresh work is still background and was stamped.
assert_eq background "$(state_of alive)" 'a live child keeps the pane background past the grace'
assert_eq 1 "$(( $(alive_at_of alive) >= t_pass2 ))" '@ab_bg_alive_at keeps advancing past the grace'
assert_eq background "$(state_of fresh)" 'a fresh output file keeps the pane background past the grace'
assert_eq background "$(state_of unknown)" 'unknown work does not end past the grace'
assert_eq '1 background? watch live updates' "$(action_of unknown)" 'unknown stays marked'

# ---- (h) the age of the oldest running process ------------------------------------------
# Nothing under 10 minutes, then the age in the sidebar's style; work with no
# process (an output file only) never shows one.
set_etime() { printf '%s\n' "$1" >"$TMP_DIR/ps-etime"; }
set_etime 09:59
reconcile
assert_eq '1 background: sleep 900' "$(action_of alive)" 'a process 9m59s old keeps the plain row'
set_etime 10:00
reconcile
assert_eq '1 background · 10m: sleep 900' "$(action_of alive)" 'a process 10 minutes old shows its age'
assert_eq '1 background: sleep 900' "$(action_of fresh)" 'output-file-only work has no process age'
set_etime 3:25:00
reconcile
assert_eq '1 background · 3h: sleep 900' "$(action_of alive)" 'hours read as 3h'
set_etime 2-03:04:05
reconcile
assert_eq '1 background · 2d: sleep 900' "$(action_of alive)" 'days read as 2d'
set_etime 20-00:00:01
reconcile
assert_eq '1 background · 2w: sleep 900' "$(action_of alive)" 'weeks read as 2w'
rm -f "$TMP_DIR/ps-etime"
reconcile
assert_eq '1 background: sleep 900' "$(action_of alive)" 'a young process drops the age again'

# ---- the real sidebar: its refresh job runs the same check -------------------------
tmux set-option -gq @orchestra_bg_interval 1
TMUX_PANE=$(cat "$TMP_DIR/focus.pane") orchestra-toggle
sidebar=$(opt @orchestra_sidebar_pane_id)
[ -n "$sidebar" ] || { printf 'sidebar did not open\n' >&2; exit 1; }
alive_row_shows() { row_of alive | grep -qF '1 background: sleep 900' && printf 1; }
wait_eq 1 'the sidebar draws the live row as "N background: cmd"' alive_row_shows
assert_eq 0 "$(row_of alive | grep -cF 'background?')" 'no marker on live work'
assert_eq 0 "$(row_of alive | grep -cF ' idle ')" 'no idle age on live work'
unknown_row_shows() { row_of unknown | grep -qF '1 background? idle' && printf 1; }
wait_eq 1 'the sidebar draws unknown work as "background? idle"' unknown_row_shows
# The colour: the live row is not the grey of the marker row.
esc=$(printf '\033')
row_color() {
    ansi_row_of "$1" | sed -n "s/.*${esc}\\[\\(38;2;[0-9;]*\\)m[0-9] background.*/\\1/p" | head -n 1
}
live_color=$(row_color alive)
unknown_color=$(row_color unknown)
assert_eq '38;2;128;128;128' "$unknown_color" 'the marker row is drawn grey'
if [ -z "$live_color" ] || [ "$live_color" = "$unknown_color" ]; then
    assert_eq 'a colour other than grey' "$live_color" 'live work is not drawn grey'
fi

# ---- (h) the sidebar draws the age, and drops it when the child is killed --------------
set_etime 2-03:04:05
aged_row_shows() { row_of alive | grep -qF '1 background · 2d:' && printf 1; }
wait_eq 1 'the sidebar draws "N background · 2d: cmd" for old work' aged_row_shows
assert_eq 0 "$(row_of alive | grep -cF 'background?')" 'aged live work is not marked unknown'

# ---- (c) kill the real child: the pane ends once the grace has passed ----------------
child_pid=$(cat "$TMP_DIR/alive.child")
for kid in $(pgrep -P "$child_pid"); do kill "$kid"; done
kill "$child_pid"
wait_eq 0 'the child shell is gone' sh -c "kill -0 $child_pid 2>/dev/null && echo 1 || echo 0"
last_stamp=$(alive_at_of alive)
aged_row_gone() { row_of alive | grep -qF ' · 2d:' && printf 0 || printf 1; }
wait_eq 1 'the age disappears from the row once the child is gone' aged_row_gone
assert_eq '1 background: sleep 900' "$(action_of alive)" 'the action is plain again once the child is gone'
sleep 2
assert_eq background "$(state_of alive)" 'killed work is still background before the grace passes'
wait_eq '' 'killed work ends once the grace has passed' state_of alive
assert_eq 1 "$(( $(now) >= last_stamp + ORCHESTRA_BG_GRACE ? 1 : 0 ))" 'it did not end before the grace'
# The state clears just before the notification lands: wait for the unread.
wait_eq 1 'the unfocused pane that ends is unread' popt alive @ab_unread
assert_eq '' "$(popt alive @ab_bg_tasks)" 'the ended pane forgets its tasks'
alive_done_shows() { row_of alive | grep -qF background && printf 0 || printf 1; }
wait_eq 1 'the sidebar row no longer says background' alive_done_shows

# ---- (e) the fresh output file stops being written: it ends too -------------------------
wait_eq '' 'work whose output file went quiet ends after the grace' state_of fresh
wait_eq 1 'the quiet pane is unread when it ends' popt fresh @ab_unread

# ---- (d) unknown work never ends ---------------------------------------------------------
assert_eq background "$(state_of unknown)" 'unknown work is still background after the grace'
assert_eq '1 background? watch live updates' "$(action_of unknown)" 'unknown stays marked'
assert_eq 1 "$(row_of unknown | grep -cF '1 background? idle')" 'the sidebar still shows the marker'

printf 'test_bgalive_e2e: all passed\n'
