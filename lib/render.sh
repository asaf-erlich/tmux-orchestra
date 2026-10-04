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

# Color of an agent state: running takes its spinner color; the others come
# from the globals bg_color, compact_color, error_color (header fields 6-8,
# defaults in set_state_colors) and the wait_color argument.
function state_color(state, spinner, wait_color) {
	if (state == "running") return spinner_color(spinner)
	if (state == "waiting") return wait_color
	if (state == "background") return bg_color
	if (state == "compacting") return compact_color
	if (state == "error") return error_color
	return ""
}

# Fill the state colors left empty with the defaults (orchestra.tmux sets the
# same values on the @orchestra_*_color options).
function set_state_colors() {
	if (bg_color == "") bg_color = "#58a6ff"
	if (compact_color == "") compact_color = "#bc8cff"
	if (error_color == "") error_color = "#e3b341"
	if (done_color == "") done_color = "#3fb950"
}

# States that keep the agent busy or need you: everything but idle.
function live_state(state) {
	return state == "running" || state == "waiting" || state == "background" || state == "compacting" || state == "error"
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
	if (state == "background") {
		if (nerd == "on") return pick("◴,◷,◶,◵", 4, frame)
		return "&"
	}
	if (state == "compacting") {
		if (nerd == "on") return pick("◜,◝,◞,◟", 4, frame)
		return "="
	}
	if (state == "error") return (nerd == "on") ? "✗" : "X"
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

# Idle with no prompt since /clear or a fresh start (@ab_session_source):
# nothing to come back to. "agents" is the `claude agents` manager view.
function empty_text(source) {
	if (source == "clear") return "∅ cleared"
	if (source == "agents") return "◇ agents view"
	if (source != "") return "∅ empty session"
	return ""
}

function activity_text(state, action, cwd, last_cmd, prompt, source) {
	if (live_state(state)) return action
	if (prompt != "") return "❯ " prompt
	if (source != "") return empty_text(source)
	# Sharing the row with the command, the directory keeps its first 24
	# characters; alone it is trimmed to the row width like any other text.
	if (cwd != "" && last_cmd != "") return trim(24, cwd_label(cwd)) "  $ " last_cmd
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
# f[] holds the pipe-separated fields of one input line (one pane); f[23] is
# @ab_session_source and f[27] the last prompt with any "|" it contained
# rejoined.
function window_block(f, width, frame, nerd, wait_color, selected,    active, state, title, pad, activity, glyph, gcolor, pill, ptext, meta, tl, h, v, bs, be, title_style, row_style, show_dot, before_dot, out, since, age, tail, idle, empty, row_color, scolor, needs_you, unread_done) {
	active = f[4]; state = f[5]

	# How long ago the agent last finished (@ab_finished_at, falling back to
	# the last output in the window), right-aligned in the top border. Hidden
	# while running or compacting: the spinner says more.
	age = ""
	if (state != "running" && state != "compacting") {
		since = (f[21] != "") ? f[21] : f[22]
		age = age_text(since)
	}
	tail = (age != "") ? length(age) + 3 : 0

	title = trim(width - 4 - tail, f[3] named_branch(f[7], nerd))
	pad = width - length(title) - 4 - tail
	if (pad < 0) pad = 0

	idle = !live_state(state)
	empty = (idle && f[27] == "" && f[23] != "")
	activity = activity_text(state, f[6], f[8], f[9], f[27], f[23])
	glyph = state_glyph(state, frame, nerd, f[17])
	gcolor = spinner_color(f[17])
	# Finished while you were elsewhere (unread): rows in the done color and,
	# with Nerd Fonts, a check mark (without, the unread "!" in the border
	# already says it).
	unread_done = (idle && !empty && f[12] == "1")
	if (unread_done && nerd == "on") glyph = state_glyph("done", frame, nerd, "")
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
	# Otherwise the meta row carries what the activity row has no room for:
	# the prompt while the agent works on it, the directory once the prompt or
	# the empty-session marker took the activity row. The last notification
	# is only a fallback (unread already shows as the dot).
	if (meta == "" && f[27] != "" && !idle) meta = "❯ " f[27]
	else if (meta == "" && (f[27] != "" || empty)) meta = cwd_label(f[8])
	else if (meta == "") meta = f[13]
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

	# Each state has its own color (state_color). Waiting on you and errors
	# also color the title; every state but running colors its rows (running
	# colors only the spinner), as does an unread finish; an empty session
	# reads dim grey.
	scolor = unread_done ? done_color : state_color(state, f[17], wait_color)
	needs_you = (state == "waiting" || state == "error")
	title_style = ""
	if (active == "1" && needs_you) title_style = "bold_color"
	else if (active == "1") title_style = "bold"
	else if (needs_you) title_style = "color"
	row_style = ((live_state(state) && state != "running") || empty || unread_done) ? "color" : ""
	row_color = empty ? "#808080" : scolor

	# Unread: a red dot replaces the second-to-last character of the top
	# border, unless the title fills the row (the meta row still shows the
	# notification summary).
	show_dot = (f[12] == "1" && pad >= 2)
	before_dot = show_dot ? pad - 2 : pad

	out = bs tl h " " be
	if (selected) out = out INVERSE
	out = out with_style(title_style, scolor, title)
	if (selected) out = out RESET
	out = out bs " " repeat(h, before_dot) be
	if (show_dot) out = out color_start("red") ((nerd == "on") ? "●" : "!") RESET bs h be
	if (age != "") out = out bs " " be age_styled(since, age) bs " " h be
	out = out "\n"

	out = out bs v be
	if (glyph != "") {
		if (row_style == "color") out = out color_start(row_color) glyph RESET
		else if (gcolor != "") out = out color_start(gcolor) glyph RESET
		else out = out glyph
		if (activity != "") out = out " " with_style(row_style, row_color, activity)
	} else {
		out = out " " with_style(row_style, row_color, activity)
	}
	out = out EL "\n"

	return out bs v " " be with_style(row_style, row_color, meta) EL "\n"
}

# The one-line rule between the windows and the background sessions.
# Counted by hand: awk length() may count bytes, and "─" is three.
function bg_separator(width) {
	if (width < 14) return with_style("color", "#808080", repeat("─", width)) EL "\n"
	return with_style("color", "#808080", "── background " repeat("─", width - 14)) EL "\n"
}

# One background session (`claude agents` kind "background", recorded by
# bin/orchestra-bg-refresh in @orchestra_bg_agents) as a window_block. rec is
# "id;state;started_at;cwd;name" (the refresh strips ";" and "|" from the
# fields). The block id is "bg:<id>", which is also how the keyboard
# selection names it.
function bg_block(rec, width, frame, nerd, wait_color, selected,    r, g, st, id) {
	split(rec, r, ";")
	id = r[1]
	for (g = 1; g <= 27; g++) g_f[g] = ""
	g_f[2] = "bg:" id
	g_f[3] = (r[5] != "") ? r[5] : id
	g_f[4] = "0"
	g_f[8] = r[4]
	g_f[17] = "claude"
	st = r[2]
	if (st == "blocked" || st == "waiting" || st == "needs_input") {
		g_f[5] = "waiting"; g_f[6] = "needs input"
	} else if (st == "running" || st == "working" || st == "busy") {
		g_f[5] = "running"; g_f[6] = "working"
	} else if (st == "done" || st == "idle") {
		g_f[5] = "done"
	}
	# Idle blocks show the directory on the activity row; the meta row names
	# the session to attach to (and a state this does not know). The age is
	# measured from the start: the daemon does not record when a turn
	# finished.
	g_f[13] = "bg " id
	if (g_f[5] == "running" || g_f[5] == "waiting") g_f[13] = g_f[13] "  " cwd_label(r[4])
	else if (g_f[5] == "" && st != "") g_f[13] = g_f[13] "  " st
	g_f[22] = r[3]
	return window_block(g_f, width, frame, nerd, wait_color, selected)
}
'

# Main program. mode=rows: every input line is a block; width, nerd,
# wait_color, sel and now come from -v. mode=frame: the first line is
# "WIDTH|NERD|WAIT_COLOR|VIEW_SESSION|NOW|BG|COMPACT|ERROR|DONE" (NOW, epoch
# seconds, is empty live and fixed in tests; the last four are the state
# colors, empty for the defaults), then one line per pane of the server
# (list-panes -a); only Claude panes (field 20) are shown, once each, in input
# order. A block is titled "session:window", or "session:window.PANE_INDEX"
# when its window has several Claude panes. The selection is derived from
# fields 18-19. Fields 24-26 are pane_id, pane_index and 1 for the window's
# active pane, 2 for its previously active one (pane_last), else 0; empty
# (an older dump) means one block per window as before. A block's id is its
# pane_id, else its window_id. window_active (field 4) is per session, so only
# a pane of the active window of VIEW_SESSION (the sidebar's own session,
# i.e. what the viewing client shows) is drawn as active: its active pane,
# else its previously active one, else its first Claude pane. An empty
# VIEW_SESSION keeps field 4 as is.
# shellcheck disable=SC2016 # awk program, not shell.
_RENDER_AWK_MAIN='
BEGIN { FS = "|"; set_state_colors(); active_rank = 9 }
mode == "frame" && NR == 1 {
	width = $1; nerd = $2; wait_color = $3; view = $4; now = $5
	bg_color = $6; compact_color = $7; error_color = $8; done_color = $9
	set_state_colors()
	next
}
# "|bg|REC|REC..." (session names are never empty): @orchestra_bg_agents,
# one record per background session, drawn after the windows.
mode == "frame" && $1 == "" && $2 == "bg" {
	for (i = 3; i <= NF; i++) if ($i != "") { nb++; bg[nb] = $i }
	next
}
$2 == "" { next }
mode != "frame" { n++; line[n] = $0; next }
{
	# Field 18 is @orchestra_selected_window (same on every line), field 19
	# is 1 on the sidebar pane when it is the active pane of the active
	# window, i.e. the sidebar has focus.
	s = $18
	if ($19 == "1") focused = 1
	# Field 20 is 1 when the pane runs Claude Code. Other panes are hidden,
	# which also hides @ab_agent_state etc. left behind when Claude exited
	# without its Stop hook. A pane of a window linked into several sessions
	# is listed under the first.
	if ($20 != "1") next
	key = ($24 != "") ? $24 : $2
	if ($4 == "1" && (view == "" || $1 == view)) {
		rank = ($26 == "1" || $24 == "") ? 1 : ($26 == "2") ? 2 : 3
		if (rank < active_rank) { active_rank = rank; active_id = key }
	}
	if (key in seen) next
	seen[key] = 1
	n++
	line[n] = $0
	panes[$2]++
	if (n == 1) first_id = key
	if (key == s) valid = 1
}
END {
	if (mode == "frame") {
		if (width !~ /^[0-9]+$/) width = 32
		# An empty NOW is the live path: POSIX srand() returns the previous
		# seed, which srand() with no argument set to the time of day.
		if (now == "") { srand(); now = srand() }
		for (i = 1; i <= nb; i++) {
			split(bg[i], r, ";")
			if ("bg:" r[1] == s) valid = 1
		}
		# Show the selection while focused, falling back to the active pane
		# (or the first listed one when the active window is not listed) when
		# the stored id is unset or stale. Unfocused, show it only if it points
		# somewhere other than the active pane (mouse wheel).
		sel = ""
		if (valid) { if (focused || s != active_id) sel = s }
		else if (focused) sel = (active_id != "") ? active_id : first_id
	}
	init_styles()
	out = ""
	for (i = 1; i <= n; i++) {
		nf = split(line[i], f, "|")
		for (j = 28; j <= nf; j++) f[27] = f[27] "|" f[j]
		key = (f[24] != "") ? f[24] : f[2]
		if (mode == "frame") {
			f[4] = (key == active_id) ? "1" : "0"
			f[3] = f[1] ":" f[3]
			if (panes[f[2]] > 1 && f[25] != "") f[3] = f[3] "." f[25]
		}
		out = out window_block(f, width, frame, nerd, wait_color, sel != "" && (key == sel || f[2] == sel))
	}
	if (mode == "frame" && n == 0) out = " " trim(width - 1, "no claude sessions") EL "\n"
	# Background sessions: one separator line, then 3-line blocks (select_row
	# in lib/select.sh maps clicks with the same geometry).
	if (nb > 0) {
		out = out bg_separator(width)
		for (i = 1; i <= nb; i++) {
			split(bg[i], r, ";")
			out = out bg_block(bg[i], width, frame, nerd, wait_color, sel != "" && "bg:" r[1] == sel)
		}
	}
	printf "%s", out
}
'

# Usage: render_rows WIDTH FRAME NERD WAIT_COLOR [SELECTED_ID] [NOW]
# SELECTED_ID (a pane or window id) marks the keyboard selection; empty means
# none. Fields 18-20 and 25-26 of each input line are ignored; 21-24 and 27
# are as in render_frame. NOW (epoch seconds) is what finish times are
# measured against; empty means no ages are shown.
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
# window_activity, @ab_session_source, pane_id, pane_index, the active-pane
# flag and @ab_last_prompt as 21-27; the prompt comes last since it may
# itself contain "|") and renders one block per Claude pane, or a
# placeholder line when there is none. A non-numeric WIDTH falls back to 32. An optional
# "|bg|REC|..." line (@orchestra_bg_agents) adds a separator and one block per
# background session after the windows.
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
