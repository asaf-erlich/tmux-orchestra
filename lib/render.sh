# Pure rendering helpers for the sidebar. Tests source this file directly with
# fixture data, while the renderer feeds it one line per tmux pane.
#
# The whole frame is produced by a single awk process: process creation is
# slow on some systems (endpoint security scanning every exec), so rendering
# must not fork per window, per line or per field. Lengths and truncation use
# awk's length()/substr(), as the earlier per-field helpers did.

render_supports_color() {
	[ "${TERM:-}" != 'dumb' ] || return 1
	[ -z "${NO_COLOR:-}" ] || return 1
	[ -t 1 ] || return 1
}

# awk function library shared by render_rows, render_frame and the small
# wrappers below. Globals: color (1 = emit ANSI), RESET, BOLD, INVERSE, EL.
# shellcheck disable=SC2016
_RENDER_AWK_LIB='
function init_styles() {
	if (color) {
		RESET = "\033[0m"; BOLD = "\033[1m"; INVERSE = "\033[7m"; EL = "\033[K"
	} else {
		RESET = ""; BOLD = ""; INVERSE = ""; EL = ""
	}
}

function hexbyte(s,    i, d, v) {
	v = 0
	for (i = 1; i <= 2; i++) {
		d = index("0123456789abcdef", tolower(substr(s, i, 1)))
		if (d == 0) return v
		v = v * 16 + d - 1
	}
	return v
}

# ANSI foreground for "#rrggbb" or a basic color name (tput setaf 0-7).
function color_start(c,    hex, n) {
	if (!color) return ""
	if (substr(c, 1, 1) == "#") {
		hex = substr(c, 2)
		if (length(hex) != 6) return ""
		return sprintf("\033[38;2;%d;%d;%dm", hexbyte(substr(hex, 1, 2)), hexbyte(substr(hex, 3, 2)), hexbyte(substr(hex, 5, 2)))
	}
	n = -1
	if (c == "black") n = 0
	else if (c == "red") n = 1
	else if (c == "green") n = 2
	else if (c == "yellow") n = 3
	else if (c == "blue") n = 4
	else if (c == "magenta") n = 5
	else if (c == "cyan") n = 6
	else if (c == "white" || c == "default") n = 7
	if (n < 0) return ""
	return "\033[3" n "m"
}

function spinner_color(sp) {
	if (sp == "claude") return "#D97757"
	if (sp == "braille") return "blue"
	if (sp == "opencode") return "#38BDF8"
	return ""
}

function repeat(ch, count,    s, i) {
	s = ""
	for (i = 0; i < count; i++) s = s ch
	return s
}

function trim(w, text) {
	if (w <= 0) return ""
	if (length(text) <= w) return text
	if (w <= 1) return substr(text, 1, w)
	return substr(text, 1, w - 1) "…"
}

function named_branch(branch, nerd) {
	if (branch == "") return ""
	if (nerd == "on") return " \356\202\240 " branch
	return " git:" branch
}

function pick(list, n, frame,    a) {
	split(list, a, ",")
	return a[frame % n + 1]
}

function state_glyph(state, frame, nerd, spinner) {
	if (state == "running") {
		if (spinner == "claude") return pick("·,✻,✽,✶,✱,✢", 6, frame)
		if (spinner == "braille") return pick("⠋,⠙,⠹,⠸,⠼,⠴,⠦,⠧,⠇,⠏", 10, frame)
		# Approximate the OpenCode 4x4 pulsing square grid in two braille cells.
		if (spinner == "opencode") return pick("⢎⡱,⢞⡳,⢎⡷,⢮⡵,⢾⡱,⠰⠆,⢾⡷,⠰⠆", 8, frame)
		if (nerd == "on") return pick("⠋,⠙,⠹,⠸,⠼,⠴,⠦,⠧,⠇,⠏", 10, frame)
		return "*"
	}
	if (state == "waiting") {
		if (nerd == "on") return pick("◐,◓,◑,◒", 4, frame)
		return "?"
	}
	if (state == "done") return (nerd == "on") ? "✓" : "OK"
	return ""
}

function progress_bar(progress, label, nerd,    fill, empty, filled, percent, s) {
	if (progress == "") return ""
	if (nerd == "on") { fill = "█"; empty = "░" } else { fill = "#"; empty = "-" }
	if (progress < 0) progress = 0
	if (progress > 1) progress = 1
	filled = int(progress * 10 + 0.5)
	percent = int(progress * 100 + 0.5)
	s = repeat(fill, filled) repeat(empty, 10 - filled) " " percent "%"
	if (label != "") s = s " " label
	return s
}

function cwd_label(cwd,    n, parts, i, label) {
	if (cwd == "") return ""
	n = split(cwd, parts, "/")
	label = ""
	for (i = n; i >= 1; i--) {
		if (parts[i] != "") { label = parts[i]; break }
	}
	if (label == "") label = "/"
	if (length(label) > 16) label = substr(label, length(label) - 15)
	return label
}

# Seconds since epoch time t as "now", "5m", "3h", "2d" or "6w"; empty when
# t is not a timestamp. Uses the global now.
function age_text(t,    d) {
	if (t !~ /^[0-9]+$/ || now !~ /^[0-9]+$/) return ""
	d = now - t
	if (d < 60) return "now"
	if (d < 3600) return int(d / 60) "m"
	if (d < 86400) return int(d / 3600) "h"
	if (d < 14 * 86400) return int(d / 86400) "d"
	return int(d / 604800) "w"
}

# Within the last hour reads bold (it probably wants attention), a day or
# more reads dim grey (it is just sitting there).
function age_styled(t, text,    d) {
	d = now - t
	if (d < 3600) return with_style("bold", "", text)
	if (d >= 86400) return with_style("color", "#808080", text)
	return text
}

function activity_text(state, action, cwd, last_cmd, prompt) {
	if (state == "running" || state == "waiting") return action
	if (prompt != "") return "❯ " prompt
	if (cwd != "" && last_cmd != "") return cwd_label(cwd) "  $ " last_cmd
	if (last_cmd != "") return "$ " last_cmd
	return cwd_label(cwd)
}

# style: "bold", "color", "bold_color" or "" (none).
function with_style(style, c, text,    s) {
	s = ""
	if (style == "bold") s = BOLD
	else if (style == "color") s = color_start(c)
	else if (style == "bold_color") s = BOLD color_start(c)
	s = s text
	if (style != "") s = s RESET
	return s
}

# One window block: exactly three lines (orchestra-click depends on this).
# f[] holds the pipe-separated window fields of one input line; f[23] is the
# last prompt with any "|" it contained rejoined.
function window_block(f, width, frame, nerd, wait_color, selected,    active, state, title, pad, activity, glyph, gcolor, pill, ptext, meta, tl, h, v, bs, be, title_style, row_style, show_dot, before_dot, out, since, age, tail) {
	active = f[4]; state = f[5]

	# How long ago the agent last finished (@ab_finished_at, falling back to
	# the last output in the window), right-aligned in the top border. Hidden
	# while running: the spinner says more.
	age = ""
	if (state != "running") {
		since = (f[21] != "") ? f[21] : f[22]
		age = age_text(since)
	}
	tail = (age != "") ? length(age) + 3 : 0

	title = trim(width - 4 - tail, f[3] named_branch(f[7], nerd))
	pad = width - length(title) - 4 - tail
	if (pad < 0) pad = 0

	activity = activity_text(state, f[6], f[8], f[9], f[23])
	glyph = state_glyph(state, frame, nerd, f[17])
	gcolor = spinner_color(f[17])
	if (glyph != "" && activity != "") activity = trim(width - 3, activity)
	else if (glyph == "") activity = trim(width - 2, activity)

	# The phase pill (fields 14-15; field 16, its color, is not applied) is
	# measured and trimmed as plain text with the rest of the meta row.
	pill = ""
	if (f[14] != "") pill = (f[15] != "") ? f[15] " " f[14] : f[14]
	ptext = progress_bar(f[10], f[11], nerd)
	meta = pill
	if (ptext != "") {
		if (meta != "") meta = meta "  "
		meta = meta ptext
	}
	# Otherwise the meta row carries an unread notification, then what the
	# activity row has no room for (the prompt while the agent works on it,
	# the directory once the prompt took the activity row), then a notification
	# already seen.
	if (meta == "" && f[13] != "" && (f[12] == "1" || f[23] == "")) meta = f[13]
	else if (meta == "" && f[23] != "") {
		if (state == "running" || state == "waiting") meta = "❯ " f[23]
		else meta = cwd_label(f[8])
	}
	meta = trim(width - 2, meta)

	# Heavy border for the active window, light grey for the others.
	if (active == "1") {
		tl = "┏"; h = "━"; v = "┃"; bs = ""; be = ""
	} else {
		tl = "┌"; h = "─"; v = "│"; bs = color_start("#c0c0c0"); be = RESET
	}
	# The keyboard selection replaces the left edge of every line with a bar
	# and shows the title in reverse video, so it reads differently from the
	# heavy-bordered active window and survives NO_COLOR.
	if (selected) { tl = "▌"; v = "▌" }

	title_style = ""
	if (active == "1" && state == "waiting") title_style = "bold_color"
	else if (active == "1") title_style = "bold"
	else if (state == "waiting") title_style = "color"
	row_style = (state == "waiting") ? "color" : ""

	# Unread: a red dot replaces the second-to-last character of the top
	# border, unless the title fills the row (the meta row still shows the
	# notification summary).
	show_dot = (f[12] == "1" && pad >= 2)
	before_dot = show_dot ? pad - 2 : pad

	out = bs tl h " " be
	if (selected) out = out INVERSE
	out = out with_style(title_style, wait_color, title)
	if (selected) out = out RESET
	out = out bs " " repeat(h, before_dot) be
	if (show_dot) out = out color_start("red") ((nerd == "on") ? "●" : "!") RESET bs h be
	if (age != "") out = out bs " " be age_styled(since, age) bs " " h be
	out = out "\n"

	out = out bs v be
	if (glyph != "") {
		if (row_style == "color") out = out color_start(wait_color) glyph RESET
		else if (gcolor != "") out = out color_start(gcolor) glyph RESET
		else out = out glyph
		if (activity != "") out = out " " with_style(row_style, wait_color, activity)
	} else {
		out = out " " with_style(row_style, wait_color, activity)
	}
	out = out EL "\n"

	return out bs v " " be with_style(row_style, wait_color, meta) EL "\n"
}
'

# Main program. mode=rows: every input line is a window; width, nerd,
# wait_color, sel and now come from -v. mode=frame: the first line is
# "WIDTH|NERD|WAIT_COLOR|VIEW_SESSION|NOW" (NOW, epoch seconds, is empty
# live and fixed in tests), then one line per pane of the server
# (list-panes -a); only windows with a Claude pane (field 20) are shown, once
# each, in input order, titled "session:window", and the selection is
# derived from fields 18-19. window_active (field 4) is per session, so only
# the active window of VIEW_SESSION (the sidebar's own session, i.e. what the
# viewing client shows) is drawn as active; an empty VIEW_SESSION keeps
# field 4 as is.
# shellcheck disable=SC2016 # awk program, not shell.
_RENDER_AWK_MAIN='
BEGIN { FS = "|" }
mode == "frame" && NR == 1 { width = $1; nerd = $2; wait_color = $3; view = $4; now = $5; next }
$2 == "" { next }
mode != "frame" { n++; line[n] = $0; next }
{
	# Field 18 is @orchestra_selected_window (same on every line), field 19
	# is 1 on the sidebar pane when it is the active pane of the active
	# window, i.e. the sidebar has focus.
	s = $18
	if ($19 == "1") focused = 1
	# Field 20 is 1 when the pane runs Claude Code. Windows without one are
	# hidden, which also hides @ab_agent_state etc. left behind when Claude
	# exited without its Stop hook. Window fields are the same on every pane
	# line, so the first Claude pane stands for its window (a window linked
	# into several sessions is listed under the first).
	if ($20 != "1") next
	if ($4 == "1" && (view == "" || $1 == view)) active_id = $2
	if ($2 in seen) next
	seen[$2] = 1
	n++
	line[n] = $0
	if (n == 1) first_id = $2
	if ($2 == s) valid = 1
}
END {
	if (mode == "frame") {
		if (width !~ /^[0-9]+$/) width = 32
		# An empty NOW is the live path: POSIX srand() returns the previous
		# seed, which srand() with no argument set to the time of day.
		if (now == "") { srand(); now = srand() }
		# Show the selection while focused, falling back to the active window
		# (or the first listed one when the active window is not listed) when
		# the stored id is unset or stale. Unfocused, show it only if it points
		# somewhere other than the active window (mouse wheel).
		sel = ""
		if (valid) { if (focused || s != active_id) sel = s }
		else if (focused) sel = (active_id != "") ? active_id : first_id
	}
	init_styles()
	out = ""
	for (i = 1; i <= n; i++) {
		nf = split(line[i], f, "|")
		for (j = 24; j <= nf; j++) f[23] = f[23] "|" f[j]
		if (mode == "frame") {
			f[4] = (f[2] == active_id) ? "1" : "0"
			f[3] = f[1] ":" f[3]
		}
		out = out window_block(f, width, frame, nerd, wait_color, sel != "" && f[2] == sel)
	}
	if (mode == "frame" && n == 0) out = " " trim(width - 1, "no claude sessions") EL "\n"
	printf "%s", out
}
'

# Usage: render_rows WIDTH FRAME NERD WAIT_COLOR [SELECTED_WINDOW_ID] [NOW]
# SELECTED_WINDOW_ID marks the keyboard selection; empty means none. Fields
# 18-20 of each input line are ignored; 21-23 are the finish time, window
# activity time and last prompt as in render_frame. NOW (epoch seconds) is
# what finish times are measured against; empty means no ages are shown.
render_rows() {
	# Not $(...): render_supports_color checks whether stdout is a terminal.
	_render_color=0
	render_supports_color && _render_color=1
	awk -v mode=rows -v width="$1" -v frame="$2" -v nerd="$3" -v wait_color="$4" \
		-v sel="${5:-}" -v now="${6:-}" -v color="$_render_color" "$_RENDER_AWK_LIB$_RENDER_AWK_MAIN"
}

# Usage: render_frame FRAME
# Reads "WIDTH|NERD|WAIT_COLOR|VIEW_SESSION|NOW" followed by the list-panes
# -a dump (window fields 1-17, @orchestra_selected_window, the sidebar-focused
# flag and the Claude pane flag as fields 18-20, then @ab_finished_at,
# window_activity and @ab_last_prompt as 21-23; the prompt comes last since
# it may itself contain "|") and renders one
# "session:window" block per window that has a Claude pane, or a placeholder
# line when there is none. A non-numeric WIDTH falls back to 32.
render_frame() {
	_render_color=0
	render_supports_color && _render_color=1
	awk -v mode=frame -v frame="$1" -v color="$_render_color" "$_RENDER_AWK_LIB$_RENDER_AWK_MAIN"
}

render_cwd_label() {
	awk -v cwd="$1" "$_RENDER_AWK_LIB"'BEGIN { printf "%s", cwd_label(cwd) }'
}

# Usage: render_state_glyph STATE FRAME NERD [SPINNER]
render_state_glyph() {
	awk -v state="$1" -v frame="$2" -v nerd="$3" -v spinner="${4:-}" \
		"$_RENDER_AWK_LIB"'BEGIN { printf "%s", state_glyph(state, frame, nerd, spinner) }'
}
