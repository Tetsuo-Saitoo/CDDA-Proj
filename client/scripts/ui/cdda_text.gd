class_name CddaText
extends RefCounted
## CDDA's colour-tagged text (`<color_red>…</color>`, `<color_white_red>`, `<good>`, …, see CDDA's
## color.cpp / output.cpp) to RichTextLabel BBCode or to plain text. The text comes from the sim: a `[` in it
## is escaped, so it never becomes a BBCode tag, and unknown tags stay as literal text (as in CDDA).

const MAX_CHARS := 20000
const MAX_DEPTH := 32
const MAX_TAG := 48

## CDDA's default palette (data/raw/colors.json). Black is lifted a little so it shows on a dark panel.
const COLORS := {
	"black": "#3c3c3c", "white": "#ffffff", "light_gray": "#969696", "dark_gray": "#636363",
	"red": "#ff0000", "green": "#006e00", "blue": "#0000c8", "cyan": "#0096b4", "magenta": "#8b3a62",
	"brown": "#5c3317", "light_red": "#ff9696", "light_green": "#00ff00", "light_blue": "#6464ff",
	"light_cyan": "#00f0ff", "pink": "#fe00fe", "yellow": "#ffff00",
}
## Background of CDDA's highlighted colours (`h_`).
const HIGHLIGHT_BG := "#0000c8"
## Shorthand tags CDDA's replace_colors() expands.
const INFO_TAGS := {
	"info": "cyan", "stat": "light_blue", "header": "magenta", "bold": "white", "dark": "dark_gray",
	"good": "green", "bad": "red", "neutral": "yellow",
}

static var _bases_longest_first: Array = []


## BBCode for a RichTextLabel with bbcode_enabled.
static func to_bbcode(s: String) -> String:
	return _convert(s, true)


## The text without colour tags (for filtering, logs, plain Labels).
static func plain(s: String) -> String:
	return _convert(s, false)


static func _convert(s: String, bbcode: bool) -> String:
	if s.length() > MAX_CHARS:
		s = s.left(MAX_CHARS)
	var out := PackedStringArray()
	var closers := PackedStringArray()   # BBCode that closes each open colour tag
	var i := 0
	var n := s.length()
	while i < n:
		var lt := s.find("<", i)
		if lt < 0:
			out.append(_escape(s.substr(i), bbcode))
			break
		out.append(_escape(s.substr(i, lt - i), bbcode))
		var gt_rel := s.substr(lt, MAX_TAG + 1).find(">")
		var gt := lt + gt_rel
		if gt_rel < 0:
			out.append("<")
			i = lt + 1
			continue
		var tag := s.substr(lt + 1, gt - lt - 1)
		var opened := _open_tag(tag)
		if opened != "":
			if closers.size() < MAX_DEPTH:
				if bbcode:
					out.append(opened)
				closers.append("[/bgcolor][/color]" if opened.contains("[bgcolor=") else "[/color]")
			i = gt + 1
		elif tag == "/color" or (tag.begins_with("/") and INFO_TAGS.has(tag.substr(1))):
			if not closers.is_empty():
				if bbcode:
					out.append(closers[closers.size() - 1])
				closers.resize(closers.size() - 1)
			i = gt + 1
		else:
			out.append("<")   # not a colour tag: literal text, like CDDA
			i = lt + 1
	if bbcode:
		for j in range(closers.size() - 1, -1, -1):
			out.append(closers[j])
	return "".join(out)


static func _escape(s: String, bbcode: bool) -> String:
	return s.replace("[", "[lb]") if bbcode else s


## BBCode opening a colour tag's colours, "" if `tag` (between < and >) isn't a colour CDDA knows.
static func _open_tag(tag: String) -> String:
	if INFO_TAGS.has(tag):
		return "[color=%s]" % COLORS[INFO_TAGS[tag]]
	if not tag.begins_with("color_"):
		return ""
	var fg_bg := parse_color(tag.substr(6))
	if fg_bg.is_empty():
		return ""
	if fg_bg[1] == "":
		return "[color=%s]" % fg_bg[0]
	return "[color=%s][bgcolor=%s]" % fg_bg


## [fg, bg] hex colours of a CDDA colour name (`red`, `c_red`, `ltred`, `white_red`, `i_red`, `h_red`), bg ""
## if none; [] if the name is unknown.
static func parse_color(name: String) -> Array:
	var prefix := "c"
	if name.length() > 1 and name[1] == "_":
		prefix = name[0]
		name = name.substr(2)
	if prefix != "c" and prefix != "i" and prefix != "h":
		return []
	# CDDA's color_from_string turns the short forms into the long ones.
	name = name.replace("lt", "light_").replace("dk", "dark_")
	var fg := ""
	var bg := ""
	if COLORS.has(name):
		fg = name
	else:
		for b: String in _bases():
			if name.begins_with(b + "_") and COLORS.has(name.substr(b.length() + 1)):
				fg = b
				bg = name.substr(b.length() + 1)
				break
	if fg == "":
		return []
	match prefix:
		"i":   # inverted: black on the colour
			return [COLORS["black"], COLORS[fg]] if bg == "" else []
		"h":   # highlighted: the colour on blue
			return [COLORS[fg], HIGHLIGHT_BG] if bg == "" else []
	return [COLORS[fg], "" if bg == "" else COLORS[bg]]


static func _bases() -> Array:
	if _bases_longest_first.is_empty():
		_bases_longest_first = COLORS.keys()
		_bases_longest_first.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())
	return _bases_longest_first
