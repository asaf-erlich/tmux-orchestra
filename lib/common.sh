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

clear_opt() {
    target=$1
    option=$2
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

# Usage: clear_window_agent_opts PANE
# Unsets AB_AGENT_OPTS on PANE's window in one tmux call. Every pane inherits
# window options, so agent state an earlier version (or a window-scoped
# `orchestra set-state`) left on the window would otherwise show on every
# pane without its own value.
clear_window_agent_opts() {
    _ab_target=$1
    set --
    for _ab_opt in $AB_AGENT_OPTS; do
        [ $# -eq 0 ] || set -- "$@" ';'
        set -- "$@" set-option -wqu -t "$_ab_target" "$_ab_opt"
    done
    tmux "$@" >/dev/null 2>&1
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
