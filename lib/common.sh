# Shared helpers for tmux-orchestra. This file is sourced by executables, so it
# intentionally avoids `set -e` and only exposes reusable functions.

AB_EXIT_USAGE=1
AB_EXIT_NOTMUX=2
AB_EXIT_TMUX=3

ab_err() {
    printf '%s\n' "$*" >&2
}

ab_usage() {
    ab_err "$*"
    exit "$AB_EXIT_USAGE"
}

ab_notmux() {
    ab_err "$*"
    exit "$AB_EXIT_NOTMUX"
}

ab_tmux_fail() {
    ab_err "$*"
    exit "$AB_EXIT_TMUX"
}

ab_plugin_dir() {
    CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd
}

ab_option_max() {
    case "$1" in
        @ab_current_action) printf '%s' 120 ;;
        @ab_progress_label) printf '%s' 60 ;;
        @ab_last_notification) printf '%s' 120 ;;
        @ab_last_cmd) printf '%s' 80 ;;
        @ab_last_prompt) printf '%s' 120 ;;
        @ab_last_exit) printf '%s' 32 ;;
        @ab_status_*__icon) printf '%s' 1 ;;
        @ab_status_*__color) printf '%s' 32 ;;
        @ab_status_*) printf '%s' 40 ;;
        @ab_width) printf '%s' 8 ;;
        *) printf '%s' 0 ;;
    esac
}

ab_normalize_value() {
    printf '%s' "$1" | tr '\n' ' '
}

ab_truncate_value() {
    max=$1
    value=$2

    if [ "$max" -le 0 ]; then
        printf '%s' "$value"
        return 0
    fi

    printf '%s' "$value" | awk -v max="$max" '
        BEGIN { ORS = "" }
        {
            text = $0
            if (length(text) <= max) {
                print text
            } else if (max <= 1) {
                print substr(text, 1, max)
            } else {
                print substr(text, 1, max - 1) "…"
            }
        }
    '
}

# The scope flag for a target: a pane id (%N) gets pane options, anything
# else (a window id or name) window options. Pane options win over window
# options in #{@opt} formats, so a pane with no value of its own shows its
# window's.
ab_scope() {
    case "$1" in
        %*) printf '%s' -p ;;
        *) printf '%s' -w ;;
    esac
}

set_opt() {
    target=$1
    option=$2
    value=$(ab_normalize_value "$3")
    max=$(ab_option_max "$option")
    value=$(ab_truncate_value "$max" "$value")
    tmux set-option "$(ab_scope "$target")" -q -t "$target" "$option" "$value" >/dev/null 2>&1
}

# A pane's agent options are emptied, not unset: unset, the pane would show
# its window's value (see shadow_pane_agent_opts).
clear_opt() {
    target=$1
    option=$2
    case "$target" in
        %*)
            case " $AB_AGENT_OPTS " in
                *" $option "*)
                    tmux set-option -pq -t "$target" "$option" '' >/dev/null 2>&1
                    return
                    ;;
            esac
            ;;
    esac
    tmux set-option "$(ab_scope "$target")" -qu -t "$target" "$option" >/dev/null 2>&1
}

# The target's own value: a pane's value does not fall back to its window's.
get_opt() {
    target=$1
    option=$2
    tmux show-options -v "$(ab_scope "$target")" -t "$target" "$option" 2>/dev/null || printf ''
}

# Agent state options the Claude Code hook writes per pane.
AB_AGENT_OPTS='@ab_agent_state @ab_current_action @ab_spinner @ab_finished_at @ab_unread @ab_last_notification @ab_session_source @ab_last_prompt'

# Usage: shadow_pane_agent_opts PANE
# Gives PANE an empty value of its own for each AB_AGENT_OPTS option it has
# none for, in one tmux call. A pane with no value of its own shows its
# window's, and window-scoped agent state comes from writers that cannot name
# a pane: an earlier version, `orchestra set-state --window`, or a Claude
# session the daemon hosts (`claude --bg`, `claude attach`), whose hooks get
# no $TMUX_PANE. An empty pane value hides it, so a Claude pane with its own
# hooks never shows another session's state; clearing the window instead would
# wipe the state of the session that wrote it.
shadow_pane_agent_opts() {
    _ab_pane=$1
    _ab_own=$(tmux show-options -p -t "$_ab_pane" 2>/dev/null) || return 0
    set --
    for _ab_opt in $AB_AGENT_OPTS; do
        case "
$_ab_own
" in
            *"
$_ab_opt "*) continue ;;
        esac
        [ $# -eq 0 ] || set -- "$@" ';'
        set -- "$@" set-option -pq -t "$_ab_pane" "$_ab_opt" ''
    done
    [ $# -eq 0 ] || tmux "$@" >/dev/null 2>&1
}

set_session_opt() {
    target=$1
    option=$2
    value=$(ab_normalize_value "$3")
    max=$(ab_option_max "$option")
    value=$(ab_truncate_value "$max" "$value")
    tmux set-option -q -t "$target" "$option" "$value" >/dev/null 2>&1
}

clear_session_opt() {
    target=$1
    option=$2
    tmux set-option -qu -t "$target" "$option" >/dev/null 2>&1
}

get_session_opt() {
    target=$1
    option=$2
    tmux show-options -v -t "$target" "$option" 2>/dev/null || printf ''
}

resolve_window() {
    explicit_window=${1-}

    if [ -n "$explicit_window" ]; then
        printf '%s\n' "$explicit_window"
        return 0
    fi

    if [ -n "${TMUX_PANE:-}" ]; then
        tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null && return 0
    fi

    if [ -n "${ORCHESTRA_WINDOW_ID:-}" ]; then
        printf '%s\n' "$ORCHESTRA_WINDOW_ID"
        return 0
    fi

    tmux display-message -p '#{window_id}' 2>/dev/null && return 0
    ab_notmux 'not in tmux and no --window given.'
}

# Usage: resolve_target WINDOW PANE
# A --pane id when given (pane-scoped options), else resolve_window WINDOW.
resolve_target() {
    if [ -n "${2-}" ]; then
        case "$2" in
            %*) printf '%s\n' "$2"; return 0 ;;
            *) ab_usage "--pane takes a pane id (%N): $2" ;;
        esac
    fi
    resolve_window "${1-}"
}

resolve_session() {
    window_id=$1
    tmux display-message -p -t "$window_id" '#{session_name}' 2>/dev/null || return 1
}

window_exists() {
    # display-message can exit 0 with empty output for a target that no longer
    # exists, so treat an empty result as missing.
    [ -n "$(tmux display-message -p -t "$1" '#{window_id}' 2>/dev/null)" ]
}

pane_exists() {
    # display-message can exit 0 with empty output for a target that no longer
    # exists, so treat an empty result as missing.
    [ -n "$(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null)" ]
}

# The sidebar sits at a window's left edge (-f). Entering takes its columns
# from every cell of the window; leaving gives them all to the left-most
# cell, so each visit would move width from the right panes to the left
# ones. To stay net-neutral, entering records the window's layout from just
# before and just after (window options @orchestra_layout_before and
# @orchestra_layout_with) and leaving puts the "before" layout back, but only
# if the window still has the exact "with" layout (pane ids, sizes): if the
# user resized or added or removed panes meanwhile, the saved layout no
# longer applies and is just dropped. select-layout assigns cells in order,
# so it needs the same panes; the "with" match guarantees that.

# Usage: sidebar_layout_save WINDOW BEFORE
# Call after the sidebar entered WINDOW, whose layout was BEFORE.
sidebar_layout_save() {
    _sl_with=$(tmux display-message -p -t "$1" '#{window_layout}' 2>/dev/null) || return 0
    [ -n "$_sl_with" ] && [ -n "$2" ] || return 0
    tmux set-option -wq -t "$1" @orchestra_layout_before "$2" \; \
        set-option -wq -t "$1" @orchestra_layout_with "$_sl_with" >/dev/null 2>&1 || true
}

# display-message format giving "window_id|LAYOUT|WITH|BEFORE": a window's
# current layout and the two saved ones. Layouts never contain "|".
# shellcheck disable=SC2034 # Read by orchestra-follow and orchestra-toggle.
SIDEBAR_LAYOUT_FORMAT='#{window_id}|#{window_layout}|#{@orchestra_layout_with}|#{@orchestra_layout_before}'

# Usage: sidebar_layout_restore INFO
# Call after the sidebar left a window, with INFO the SIDEBAR_LAYOUT_FORMAT
# line read for that window while the sidebar was still in it. A window that
# closed when the sidebar left (it was its only pane) fails silently.
sidebar_layout_restore() {
    _sl_win=${1%%|*}
    _sl_rest=${1#*|}
    _sl_now=${_sl_rest%%|*}
    _sl_rest=${_sl_rest#*|}
    _sl_with=${_sl_rest%%|*}
    _sl_before=${_sl_rest#*|}
    [ -n "$_sl_win" ] || return 0
    if [ -n "$_sl_before" ] && [ "$_sl_now" = "$_sl_with" ]; then
        tmux select-layout -t "$_sl_win" "$_sl_before" \; \
            set-option -wqu -t "$_sl_win" @orchestra_layout_before \; \
            set-option -wqu -t "$_sl_win" @orchestra_layout_with >/dev/null 2>&1 && return 0
    fi
    tmux set-option -wqu -t "$_sl_win" @orchestra_layout_before \; \
        set-option -wqu -t "$_sl_win" @orchestra_layout_with >/dev/null 2>&1 || true
}

sanitize_status_key() {
    case "$1" in
        ''|*[!A-Za-z0-9_]*)
            ab_usage 'status key must contain only letters, numbers, and underscores'
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}
