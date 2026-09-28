#!/bin/sh
set -eu

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_DIR/lib/render.sh"

compare_fixture() {
    input=$1
    expected=$2
    selected=${3:-}
    actual=$(NO_COLOR=1 TERM=xterm render_rows 40 0 off '#d29922' "$selected" <"$input")
    expected_text=$(cat "$expected")
    if [ "$actual" != "$expected_text" ]; then
        printf 'render mismatch for %s\n--- expected ---\n%s\n--- actual ---\n%s\n' "$input" "$expected_text" "$actual" >&2
        exit 1
    fi
}

compare_fixture "$REPO_DIR/tests/fixtures/render-idle.input" "$REPO_DIR/tests/fixtures/render-idle.expected"
compare_fixture "$REPO_DIR/tests/fixtures/render-running.input" "$REPO_DIR/tests/fixtures/render-running.expected"
compare_fixture "$REPO_DIR/tests/fixtures/render-waiting.input" "$REPO_DIR/tests/fixtures/render-waiting.expected"
compare_fixture "$REPO_DIR/tests/fixtures/render-unread.input" "$REPO_DIR/tests/fixtures/render-unread.expected"
# Keyboard selection on the second (inactive) window: bar on its left edge,
# active window keeps its heavy border. Trailing input fields are ignored.
compare_fixture "$REPO_DIR/tests/fixtures/render-selected.input" "$REPO_DIR/tests/fixtures/render-selected.expected" '@2'

# Finish age and last prompt. With a NOW, idle windows show how long ago the
# agent finished (@ab_finished_at, else the window's last output) at the
# right of the top border; running windows do not. The last prompt takes the
# idle activity row (pushing the directory to the meta row) and the meta row
# of a working window, ahead of a notification already read; a "|" inside
# it survives.
check_age_prompt() {
    actual=$(NO_COLOR=1 TERM=xterm render_rows 40 0 off '#d29922' '' 1800000000 <"$REPO_DIR/tests/fixtures/render-age-prompt.input")
    expected_text=$(cat "$REPO_DIR/tests/fixtures/render-age-prompt.expected")
    if [ "$actual" != "$expected_text" ]; then
        printf 'render age/prompt mismatch\n--- expected ---\n%s\n--- actual ---\n%s\n' "$expected_text" "$actual" >&2
        exit 1
    fi
    # render_frame takes NOW from the header's fifth field.
    actual=$(printf '%s\n' '40|off||dev|1800000000' 'dev|@1|build|1|||||||||||||||0|1|1799999940||' | NO_COLOR=1 TERM=xterm render_frame 0 | sed -n '1p')
    if [ "$actual" != '┏━ dev:build ━━━━━━━━━━━━━━━━━━━━━━ 1m ━' ]; then
        printf 'render_frame age mismatch\nactual: %s\n' "$actual" >&2
        exit 1
    fi
}
check_age_prompt

# render_frame (the live path): width, nerd fonts and wait color come from a
# header line, the selection from fields 18-19 and the Claude pane flag from
# field 20; titles are "session:window". Unfocused (field 19 is 0) with @2
# stored while @1 is active, so @2 is shown.
check_render_frame() {
    actual=$({ printf '40|off|#d29922\n'; cat "$REPO_DIR/tests/fixtures/render-selected.input"; } | NO_COLOR=1 TERM=xterm render_frame 0)
    expected_text=$(cat "$REPO_DIR/tests/fixtures/render-selected-frame.expected")
    if [ "$actual" != "$expected_text" ]; then
        printf 'render_frame mismatch\n--- expected ---\n%s\n--- actual ---\n%s\n' "$expected_text" "$actual" >&2
        exit 1
    fi
    # Focused on the active window with nothing stored: the active window is
    # selected. A non-numeric width falls back to 32.
    actual=$(printf '%s\n' 'x|off|' 'dev|@1|build|1|||||||||||||||1|1' 'dev|@2|tests|0|||||||||||||||0|1' | NO_COLOR=1 TERM=xterm render_frame 0 | sed -n '1p;4p')
    expected_text=$(printf '%s\n' '▌━ dev:build ━━━━━━━━━━━━━━━━━━━' '┌─ dev:tests ───────────────────')
    if [ "$actual" != "$expected_text" ]; then
        printf 'render_frame focus/width mismatch\n--- expected ---\n%s\n--- actual ---\n%s\n' "$expected_text" "$actual" >&2
        exit 1
    fi
}
check_render_frame

# Only windows with a Claude pane are listed. The input is one line per pane:
# @1 has only a shell, @2 has only a shell and a stale "running" state left
# behind by a Claude that exited without its Stop hook, @3 (active) has the
# focused sidebar pane, a shell and a Claude pane, so it is listed once.
check_claude_filter() {
    actual=$({ printf '40|off|#d29922\n'; cat "$REPO_DIR/tests/fixtures/render-claude-filter.input"; } | NO_COLOR=1 TERM=xterm render_frame 0)
    expected_text=$(cat "$REPO_DIR/tests/fixtures/render-claude-filter.expected")
    if [ "$actual" != "$expected_text" ]; then
        printf 'render_frame claude filter mismatch\n--- expected ---\n%s\n--- actual ---\n%s\n' "$expected_text" "$actual" >&2
        exit 1
    fi
    # No Claude pane anywhere: a placeholder instead of a blank pane.
    actual=$(printf '%s\n' '40|off|' 'dev|@1|shell|1|running|stale||||||||||||0|1|0' | NO_COLOR=1 TERM=xterm render_frame 0)
    if [ "$actual" != ' no claude sessions' ]; then
        printf 'render_frame placeholder mismatch\nactual: %s\n' "$actual" >&2
        exit 1
    fi
    # Focused while the active window has no Claude pane: the selection
    # falls back to the first listed window.
    actual=$(printf '%s\n' '40|off|' 'dev|@1|shell|1|||||||||||||||1|0' 'dev|@2|a|0|||||||||||||||0|1' 'dev|@3|b|0|||||||||||||||0|1' | NO_COLOR=1 TERM=xterm render_frame 0 | sed -n '1p;4p')
    expected_text=$(printf '%s\n' '▌─ dev:a ───────────────────────────────' '┌─ dev:b ───────────────────────────────')
    if [ "$actual" != "$expected_text" ]; then
        printf 'render_frame fallback selection mismatch\n--- expected ---\n%s\n--- actual ---\n%s\n' "$expected_text" "$actual" >&2
        exit 1
    fi
}
check_claude_filter

# Windows from every session (list-panes -a), in input order (session name,
# then window index), titled "session:window". The header's fourth field is
# the sidebar's session (beta): only its active window (@4) is drawn active,
# not alpha's active @1. alpha's plain @2 and beta's stale-state @5 have no
# Claude pane and are hidden.
check_sessions() {
    actual=$(NO_COLOR=1 TERM=xterm render_frame 0 <"$REPO_DIR/tests/fixtures/render-sessions.input")
    expected_text=$(cat "$REPO_DIR/tests/fixtures/render-sessions.expected")
    if [ "$actual" != "$expected_text" ]; then
        printf 'render_frame sessions mismatch\n--- expected ---\n%s\n--- actual ---\n%s\n' "$expected_text" "$actual" >&2
        exit 1
    fi
    # Focused sidebar in beta with nothing stored: the selection falls back to
    # beta's active window, not alpha's.
    actual=$(printf '%s\n' '40|off||beta' 'alpha|@1|a|1|||||||||||||||0|1' 'beta|@2|b|1|||||||||||||||1|0' 'beta|@2|b|1|||||||||||||||0|1' | NO_COLOR=1 TERM=xterm render_frame 0 | sed -n '1p;4p')
    expected_text=$(printf '%s\n' '┌─ alpha:a ─────────────────────────────' '▌━ beta:b ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
    if [ "$actual" != "$expected_text" ]; then
        printf 'render_frame sessions selection mismatch\n--- expected ---\n%s\n--- actual ---\n%s\n' "$expected_text" "$actual" >&2
        exit 1
    fi
}
check_sessions

check_inactive_border_color() {
    tmp_output=$(mktemp "${TMPDIR:-/tmp}/orchestra-render.XXXXXX")
    trap 'rm -f "$tmp_output"' EXIT INT TERM

    render_supports_color() {
        return 0
    }

    TERM=xterm render_rows 40 0 off '#d29922' <"$REPO_DIR/tests/fixtures/render-running.input" >"$tmp_output"

    esc=$(printf '\033')
    first_line=$(sed -n '1p' "$tmp_output")
    second_line=$(sed -n '2p' "$tmp_output")

    case "$first_line" in
        "${esc}[38;2;192;192;192m┌─ ${esc}[0m"*)
            :
            ;;
        *)
            printf 'inactive top border is not light grey\nactual: %s\n' "$first_line" >&2
            exit 1
            ;;
    esac

    case "$second_line" in
        "${esc}[38;2;192;192;192m│${esc}[0m"*)
            :
            ;;
        *)
            printf 'inactive side border is not light grey\nactual: %s\n' "$second_line" >&2
            exit 1
            ;;
    esac

    rm -f "$tmp_output"
    trap - EXIT INT TERM
}
check_inactive_border_color

check_cwd_label() {
    cwd=$1; expected=$2
    actual=$(render_cwd_label "$cwd")
    [ "$actual" = "$expected" ] || {
        printf 'cwd label for %s: expected "%s" got "%s"\n' "$cwd" "$expected" "$actual" >&2
        exit 1
    }
}
check_cwd_label '/tmp/project' 'project'
check_cwd_label '/tmp/abcdefghijklmnopq' 'bcdefghijklmnopq'
check_cwd_label '/' '/'

check_spinner() {
    name=$1; frame=$2; expected=$3
    actual=$(render_state_glyph running "$frame" off "$name")
    [ "$actual" = "$expected" ] || {
        printf 'spinner %s frame %d: expected "%s" got "%s"\n' "$name" "$frame" "$expected" "$actual" >&2
        exit 1
    }
}
check_spinner claude 0 '·'
check_spinner claude 1 '✻'
check_spinner claude 3 '✶'
check_spinner claude 5 '✢'
check_spinner claude 6 '·'
check_spinner opencode 0 '⢎⡱'
check_spinner opencode 1 '⢞⡳'
check_spinner opencode 4 '⢾⡱'
check_spinner opencode 5 '⠰⠆'
check_spinner opencode 8 '⢎⡱'
