#!/bin/sh
# Claude Code hook: report orchestra-style session markers to herdr as pane
# metadata tokens ($session, later $prompt). Display-only; herdr owns agent state.
# Usage in settings.json: sh <path>/claude-session-meta.sh   (event comes from stdin JSON)

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

input=$(cat)
event=$(printf '%s' "$input" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
source=$(printf '%s' "$input" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)

meta() { herdr pane report-metadata "$HERDR_PANE_ID" --source orchestra "$@" >/dev/null 2>&1; }

# One shared age ticker per herdr server (see age-ticker.sh).
start_ticker() {
	pgrep -f 'age-ticker\.sh' >/dev/null 2>&1 && return 0
	nohup sh "$(dirname "$0")/age-ticker.sh" >/dev/null 2>&1 </dev/null &
}

case "$event" in
SessionStart)
	start_ticker
	case "$source" in
	clear) meta --token 'session=∅ cleared' ;;
	startup | "") meta --token 'session=∅ empty session' ;;
	compact) meta --clear-token session --clear-token state ;;
	*) meta --clear-token session ;;
	esac
	;;
Stop)
	meta --token "finished=$(date +%s)" --token 'age=now'
	start_ticker
	# Same running-task filter as RUNNING_TASKS in bin/orchestra-claude-hook:
	# keep it in sync. Needs jq; without it Stop leaves labels alone.
	command -v jq >/dev/null 2>&1 || exit 0
	pending=$(printf '%s' "$input" | jq -r '[.background_tasks[]? | select(.type != "teammate")
		| select((.status // "running") as $s
		| ["completed", "failed", "killed", "cancelled", "canceled", "stopped", "done", "error", "idle"]
		| index($s) | not)]
		| if length == 0 then empty
		  else "\(length) background: \(.[0].description // .[0].command // .[0].type // "task")"
		  end | gsub("\\s+"; " ") | .[0:32]' 2>/dev/null)
	if [ -n "$pending" ]; then
		# Shown by the $state token in the sidebar rows (not state_text).
		meta --token "state=$pending"
	else
		meta --clear-token state
	fi
	;;
StopFailure)
	# Turn ended on an API error (mirrors event_stop_failure in orchestra-claude-hook).
	error=$(printf '%s' "$input" | python3 -I -c '
import json, sys
try:
    e = json.load(sys.stdin).get("error") or ""
except Exception:
    e = ""
e = " ".join(str(e).split())
print(e[:24])
' 2>/dev/null)
	meta --token "state=✗ error: ${error:-unknown}"
	;;
PreCompact)
	# herdr has no compacting state; show it via the $state token.
	meta --token 'state=compacting'
	;;
UserPromptSubmit)
	# A prompt ends the "cleared"/"empty" state; show the prompt instead.
	prompt=$(printf '%s' "$input" | python3 -I -c '
import json, sys
try:
    p = json.load(sys.stdin).get("prompt") or ""
except Exception:
    p = ""
p = " ".join(p.split())
print(p[:119] + "…" if len(p) > 120 else p)
' 2>/dev/null)
	if [ -n "$prompt" ]; then
		meta --clear-token session --clear-token state --clear-token finished --clear-token age --token "prompt=❯ $prompt"
	else
		meta --clear-token session --clear-token state --clear-token finished --clear-token age
	fi
	;;
esac
exit 0
