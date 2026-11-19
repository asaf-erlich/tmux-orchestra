#!/bin/sh
# One shared ticker per herdr server: keeps each idle agent pane's `age` token
# (now, 5m, 3h, 2d, 6w) current from its `finished` epoch token. Herdr cannot
# recompute tokens itself. Started by claude-session-meta.sh; exits when herdr
# stops answering. Needs jq.

command -v herdr >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

INTERVAL=${ORCHESTRA_AGE_INTERVAL:-30}

# Same buckets as age_text in lib/render.sh.
age_text() {
	d=$(($(date +%s) - $1))
	[ "$d" -ge 0 ] || d=0
	if [ "$d" -lt 60 ]; then printf 'now'
	elif [ "$d" -lt 3600 ]; then printf '%sm' $((d / 60))
	elif [ "$d" -lt 86400 ]; then printf '%sh' $((d / 3600))
	elif [ "$d" -lt 604800 ]; then printf '%sd' $((d / 86400))
	else printf '%sw' $((d / 604800))
	fi
}

fails=0
while :; do
	if panes=$(herdr pane list 2>/dev/null); then
		fails=0
		printf '%s' "$panes" | jq -r '.result.panes[]?
			| select(.tokens.finished != null and .agent_status != "working")
			| "\(.pane_id) \(.tokens.finished) \(.tokens.age // "")"' 2>/dev/null |
			while read -r pane finished current; do
				case "$finished" in '' | *[!0-9]*) continue ;; esac
				new=$(age_text "$finished")
				[ "$new" = "$current" ] ||
					herdr pane report-metadata "$pane" --source orchestra --token "age=$new" >/dev/null 2>&1
			done
	else
		fails=$((fails + 1))
		[ "$fails" -lt 3 ] || exit 0
	fi
	sleep "$INTERVAL"
done
