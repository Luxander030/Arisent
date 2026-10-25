## Box-drawn tables for console output (BBCode). Rows are Arrays of cells; a cell is any
## value (bool → coloured yes/no centred, numbers right-aligned, the rest left) or a
## dictionary from cell(). Columns shrink to fit `width` characters (… truncation).
class_name ConsoleTable
extends RefCounted

enum Align { LEFT, RIGHT, CENTER }

const STYLES := {
	"single": ["┌", "┬", "┐", "├", "┼", "┤", "└", "┴", "┘", "─", "│"],
	"rounded": ["╭", "┬", "╮", "├", "┼", "┤", "╰", "┴", "╯", "─", "│"],
	"double": ["╔", "╤", "╗", "╟", "┼", "╢", "╚", "╧", "╝", "═", "║"],
	"heavy": ["┏", "┯", "┓", "┠", "┼", "┨", "┗", "┷", "┛", "━", "┃"],
	"ascii": ["+", "+", "+", "+", "+", "+", "+", "+", "+", "-", "|"],
}
const RULES := {"single": ["─", "│"], "dashed": ["┄", "┆"], "dotted": ["┈", "┊"], "ascii": ["-", "|"]}


static func cell(text: String, align := Align.LEFT, color := "") -> Dictionary:
	return {"text": text, "align": align, "color": color}


static func _cell_of(v: Variant) -> Dictionary:
	if v is Dictionary and (v as Dictionary).has("text"):
		return v
	if v == null:
		return cell("")
	if v is bool:
		return cell("yes" if v else "no", Align.CENTER, ConsoleTheme.GREEN if v else ConsoleTheme.RED)
	if v is int:
		return cell(str(v), Align.RIGHT)
	if v is float:
		var f: float = v
		return cell(str(int(f)) if f == floorf(f) and absf(f) < 1e15 else "%.2f" % f, Align.RIGHT)
	return cell(str(v))


## BBCode text of the table (no trailing newline).
static func format(rows: Array, style := "single", rule := "single", width := -1, heading := true) -> String:
	assert(not rows.is_empty(), "empty table")
	var st: Array = STYLES.get(style, STYLES.single)
	var ru: Array = RULES.get(rule, RULES.single) if style != "ascii" else RULES.ascii
	var cols := 0
	for r: Array in rows:
		cols = maxi(cols, r.size())
	var grid: Array = []
	for r: Array in rows:
		var g: Array = []
		for c in cols:
			g.append(_cell_of(r[c] if c < r.size() else null))
		grid.append(g)
	var widths := PackedInt32Array()
	widths.resize(cols)
	for g: Array in grid:
		for c in cols:
			widths[c] = maxi(widths[c], (g[c].text as String).length())
	_fit(widths, width)
	var lines := PackedStringArray()
	lines.append(_edge(widths, st[0], st[1], st[2], st[9]))
	for ri in grid.size():
		var parts := PackedStringArray()
		for c in cols:
			parts.append(" " + _pad(grid[ri][c], widths[c]) + " ")
		lines.append(ConsoleTheme.esc(st[10]) + ConsoleTheme.esc(ru[1]).join(parts) + st[10])
		if ri == 0 and heading and grid.size() > 1:
			lines.append(_edge(widths, st[3], st[4], st[5], ru[0]))
	lines.append(_edge(widths, st[6], st[7], st[8], st[9]))
	return "\n".join(lines)


static func _edge(widths: PackedInt32Array, l: String, m: String, r: String, h: String) -> String:
	var segs := PackedStringArray()
	for w in widths:
		segs.append(h.repeat(w + 2))
	return l + m.join(segs) + r


static func _fit(widths: PackedInt32Array, budget: int) -> void:
	if budget < 0:
		return
	var cols := widths.size()
	var available := budget - (cols + 1 + cols * 2)
	var total := 0
	var widest := 0
	for w in widths:
		total += w
		widest = maxi(widest, w)
	if available >= total:
		return
	if available <= cols * 3:
		for c in cols:
			widths[c] = mini(widths[c], 3)
		return
	var lo := 3
	var hi := widest
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		var s := 0
		for w in widths:
			s += mini(w, mid)
		if s <= available:
			lo = mid
		else:
			hi = mid - 1
	var orig := widths.duplicate()
	var used := 0
	for c in cols:
		widths[c] = mini(widths[c], lo)
		used += widths[c]
	var slack := available - used
	for c in cols:
		if slack <= 0:
			break
		var give := mini(slack, orig[c] - widths[c])
		widths[c] += give
		slack -= give


static func _pad(c: Dictionary, w: int) -> String:
	var t: String = c.text
	if t.length() > w:
		t = "…" if w <= 1 else t.substr(0, w - 1) + "…"
	var slack := w - t.length()
	var before := 0
	match int(c.align):
		Align.RIGHT:
			before = slack
		Align.CENTER:
			before = slack / 2
	var body := ConsoleTheme.esc(t) if str(c.color) == "" else ConsoleTheme.colored(str(c.color), t)
	return " ".repeat(before) + body + " ".repeat(slack - before)
