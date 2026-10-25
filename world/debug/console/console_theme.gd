## Colours, sizes and BBCode helpers of the developer console and the monitor panels.
## Ported from Ares Last Light's ConsoleTheme; the window is drawn in canvas pixels and
## scaled as a whole by DebugZoom.
class_name ConsoleTheme
extends RefCounted

enum Kind { TRACE, DEBUG, INFO, WARNING, ERROR, CRITICAL, INPUT }

const KIND_COLORS := ["#6E7794", "#93A2C6", "#DFE7F7", "#F2C14E", "#FF6B5E", "#FF3B30", "#7FE07F"]
const KIND_LETTERS := ["T", "D", "I", "W", "E", "C", ">"]
const STAMP_COLOR := "#4E5878"
const GREEN := "#7FE07F"
const RED := "#FF6B5E"
const AMBER := "#FFD479"

const FONT_SIZE := 16
const BORDER := 2
const TITLE_BAR := 24
const PADDING := 5
const PROMPT_WIDTH := 20
const GRIP := 14
const CLOSE := 14
const SHADOW := Vector2(8, 8)
const CARET_BLINK := 0.53
const DOUBLE_CLICK := 0.3
const DEFAULT_SIZE := Vector2(960, 480)
const MIN_SIZE := Vector2(320, 160)
const INSET := 24.0
const MAX_INPUT_ROWS := 6

const BACKGROUND := Color8(10, 16, 38)
const BORDER_COLOR := Color8(78, 107, 184)
const TITLE_BG := Color8(26, 40, 84)
const TITLE_TEXT := Color8(201, 216, 255)
const TITLE_STATUS := Color8(126, 148, 200)
const CLOSE_BG := Color8(58, 80, 140, 200)
const CLOSE_HOT := Color8(196, 72, 64, 235)
const CLOSE_GLYPH := Color8(226, 234, 255)
const INPUT_BG := Color8(6, 10, 26, 160)
const PROMPT := Color8(126, 224, 126)
const CARET := Color8(226, 234, 255)
const INPUT_TEXT := Color8(240, 244, 255)
const GHOST := Color8(240, 244, 255, 128)
const DROPDOWN_BG := Color8(14, 22, 52)
const DROPDOWN_SEL := Color8(52, 78, 150)
const DROPDOWN_TEXT := Color8(178, 192, 224)
const STATUS_BG := Color8(6, 10, 26, 200)
const STATUS_BUSY := Color8(242, 193, 78)
const STATUS_IDLE := Color8(126, 148, 200)
const SCROLL_TRACK := Color8(255, 255, 255, 20)
const SCROLL_THUMB := Color8(120, 150, 220, 150)
const SCROLL_HOT := Color8(160, 190, 255, 225)
const GRIP_COLOR := Color8(78, 107, 184, 200)
const GRIP_HOT := Color8(150, 180, 255)
const SHADOW_COLOR := Color8(2, 4, 12, 150)

static var _font: Font


## The console face: monospaced, with box-drawing characters (tables need both).
static func font() -> Font:
	if _font == null:
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Menlo", "SF Mono", "Consolas", "Cascadia Mono", "DejaVu Sans Mono",
			"Liberation Mono", "Courier New", "monospace"])
		_font = f
	return _font


static func char_width() -> float:
	return font().get_string_size("M", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x


static func row_height() -> float:
	return ceilf(font().get_height(FONT_SIZE))


## Text shown as typed: BBCode brackets escaped.
static func esc(text: String) -> String:
	return text.replace("[", "[lb]")


## `text` (plain) in the colour of a line kind.
static func markup(kind: int, text: String) -> String:
	return "[color=%s]%s[/color]" % [KIND_COLORS[kind], esc(text)]


static func green(text: String) -> String:
	return markup(Kind.INPUT, text)


static func colored(hex: String, text: String) -> String:
	return "[color=%s]%s[/color]" % [hex, esc(text)]


## BBCode → plain text (for run() results and width measuring).
static func strip(bbcode: String) -> String:
	var re := RegEx.create_from_string("\\[/?(color|b|i|u|s|code|font_size|bgcolor)(=[^\\]]*)?\\]")
	return re.sub(bbcode, "", true).replace("[lb]", "[").replace("[rb]", "]")
