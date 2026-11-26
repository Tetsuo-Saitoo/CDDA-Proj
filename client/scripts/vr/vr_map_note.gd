class_name VrMapNote
extends Node3D
## Map slice 2 in VR (lead-vr; docs/MAP.md "Notes"): the note panel laid over the map's sheet (VrMap) for one cell.
## No text entry in VR yet, so:
## - the symbol steps through PICKS (those lead-ui's MapData.NOTE_SYMBOLS allows), the colour through
##   MapData.NOTE_COLORS ([code, label, Color], CDDA's default first), the danger mark toggles and its radius steps
##   (0..MapData.MAX_DANGER_RADIUS);
## - the text is up to MAX_WORDS words picked from WORDS, in the order picked (picked again: out); editing keeps
##   the note's old text unless words are picked;
## - "Type" (only when main.gd gave VrMap the dialog) hands the cell to lead-ui's note dialog on the VR panel instead,
##   typed with the panel's keys or a desk keyboard.
## Everything is pointed at with the free hand's ray and clicked (VrMap gives the points, sheet frame). Nothing goes to
## the game from here: VrMap sends `result()` through MapData, and CDDA decides (a refusal comes back as its sentence).

const WORDS: Array[String] = ["Danger", "Zombies", "Horde", "Safe", "Cleared", "Loot", "Food", "Water", "Fuel",
		"Guns", "Tools", "Medicine", "Car", "Base", "Locked", "Later"]
const MAX_WORDS := 3
const PICKS := "N!X$+*#?"     # the symbols offered (lead-ui's suggestion), those MapData allows
## Until MapData's lists are there: CDDA's default colour and a few more ([code, label, Color]).
const COLORS := [["Y", "yellow", Color(1.0, 0.9, 0.2)], ["R", "red", Color(1.0, 0.3, 0.3)],
		["G", "green", Color(0.4, 1.0, 0.4)], ["B", "blue", Color(0.45, 0.6, 1.0)], ["C", "cyan", Color(0.4, 1.0, 1.0)],
		["W", "white", Color(1.0, 1.0, 1.0)]]
const MAX_RADIUS := 20        # CDDA's own range (MapData.MAX_DANGER_RADIUS)
const SIZE_M := Vector2(0.28, 0.28)
const Z := 0.004              # over the canvas, the marker and the wheel
const PRIORITY := 4
const INK := Color(1.0, 0.95, 0.8)
const HOVER := Color(1.0, 0.85, 0.3)
const ON := Color(0.5, 1.0, 0.6)
const BUTTON_M := Vector2(0.066, 0.022)
const MAX_SHOWN := 60         # characters of the title and the text shown
const MAX_COLORS := 32

var cell := Vector2i.MAX      # the note's cell; MAX: closed
var z := 0
var symbols: Array[String] = []   # offered this opening: _picks, and the note's own symbol first if it isn't one
var _picks: Array[String] = []    # PICKS MapData allows
var colors: Array[String] = []   # colour codes, in order
var labels := {}                 # code -> its name
var tints := {}                  # code -> Color
var max_radius := MAX_RADIUS
var symbol := 0                  # index into symbols
var color := 0                   # index into colors
var danger := false
var radius := 0
var words: Array[String] = []    # picked, in order
var old_text := ""               # the note's text before (kept unless words are picked)
var had_note := false
var keyboard := false            # "Type" offered (lead-ui's dialog)
var hover := ""                  # the button pointed at, "" none
var _buttons: Array[Dictionary] = []   # {id, rect (sheet m), label}
var _title: Label3D
var _text: Label3D
var _symbol: Label3D
var _color: Label3D
var _radius: Label3D


func _init() -> void:
	name = "Note"
	visible = false
	position.z = Z
	var back := StandardMaterial3D.new()
	back.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	back.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	back.albedo_color = Color(0.02, 0.02, 0.03, 0.88)
	back.render_priority = PRIORITY
	var q := QuadMesh.new()
	q.size = SIZE_M
	q.material = back
	var bg := MeshInstance3D.new()
	bg.name = "Back"
	bg.mesh = q
	bg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(bg)
	set_lists("", [], MAX_RADIUS)
	_title = _label(Vector2(0.0, 0.12))
	_symbol = _label(Vector2(-0.06, 0.09))
	_button("sym-", "<", Vector2(0.06, 0.09))
	_button("sym+", ">", Vector2(0.1, 0.09))
	_color = _label(Vector2(-0.06, 0.065))
	_button("col-", "<", Vector2(0.06, 0.065))
	_button("col+", ">", Vector2(0.1, 0.065))
	_button("danger", "Danger", Vector2(-0.08, 0.04))
	_radius = _label(Vector2(0.015, 0.04))
	_button("rad-", "-", Vector2(0.075, 0.04))
	_button("rad+", "+", Vector2(0.11, 0.04))
	for k in WORDS.size():
		_button("w:" + WORDS[k], WORDS[k], Vector2(-0.105 + 0.07 * (k % 4), 0.012 - 0.025 * floori(k / 4.0)))
	_text = _label(Vector2(0.0, -0.093))
	_button("save", "Save", Vector2(-0.08, -0.12))
	_button("cancel", "Cancel", Vector2(0.0, -0.12))
	_button("keyboard", "Type", Vector2(0.09, -0.12))


## MapData's lists: `allowed` its NOTE_SYMBOLS (""; all of PICKS), `cols` its NOTE_COLORS ([code, label, Color];
## bad rows dropped; none: COLORS), `top` its MAX_DANGER_RADIUS.
func set_lists(allowed: String, cols: Array, top: int) -> void:
	_picks = []
	for ch in PICKS:
		if allowed.is_empty() or allowed.contains(ch):
			_picks.append(ch)
	if _picks.is_empty():
		_picks.append("N")
	symbols = _picks.duplicate()
	colors = []
	labels = {}
	tints = {}
	for row: Variant in (cols if not cols.is_empty() else COLORS):
		if colors.size() >= MAX_COLORS:
			break
		if row is Array and (row as Array).size() >= 3 and row[0] is String and row[1] is String and row[2] is Color \
				and not (row[0] as String).is_empty() and not colors.has(row[0]):
			colors.append(row[0])
			labels[row[0]] = (row[1] as String).left(20)
			tints[row[0]] = row[2]
	if colors.is_empty():
		for row: Array in COLORS:
			colors.append(row[0])
			labels[row[0]] = row[1]
			tints[row[0]] = row[2]
	max_radius = clampi(top, 0, 1000)


func is_open() -> bool:
	return cell != Vector2i.MAX


## Opens for cell `at` on level `level`, named `title`, with its note `note` ({text, symbol (the glyph), color (its
## code), danger, radius}; {}: none). `kb`: lead-ui's dialog is there (the Type button shows).
func open(at: Vector2i, level: int, title: String, note: Dictionary, kb: bool) -> void:
	cell = at
	z = level
	had_note = not note.is_empty()
	var t: Variant = note.get("text")
	old_text = (t as String) if t is String else ""
	var s: Variant = note.get("symbol")
	symbols = _picks.duplicate()
	if s is String and (s as String).length() == 1 and not symbols.has(s) and not ":;".contains(s) \
			and (s as String).unicode_at(0) > 32 and (s as String).unicode_at(0) < 127:
		symbols.push_front(s)   # the note's own symbol kept (this opening only), even if not one of PICKS
	symbol = maxi(symbols.find(str(s)), 0)
	color = maxi(colors.find(str(note.get("color", ""))), 0)
	danger = note.get("danger") == true
	var r: Variant = note.get("radius")
	radius = clampi(r, 0, max_radius) if r is int else 0
	words = []
	keyboard = kb
	hover = ""
	_title.text = ("Edit note: " if had_note else "Note: ") + title.left(MAX_SHOWN)
	visible = true
	_paint()


func close() -> void:
	cell = Vector2i.MAX
	words = []
	hover = ""
	visible = false


## The note's text: the words picked, else the old text.
func text() -> String:
	return " ".join(words) if not words.is_empty() else old_text


## What VrMap sends (MapData.set_note): {cell, z, text, symbol, color (code), danger, radius}.
func result() -> Dictionary:
	return {"cell": cell, "z": z, "text": text(), "symbol": symbols[symbol], "color": colors[color],
			"danger": danger, "radius": radius if danger else 0}


## Per frame: the button at point `p` (sheet frame) is lit.
func hover_at(p: Variant) -> void:
	var h := _button_at(p)
	if h != hover:
		hover = h
		_paint()


## A click at point `p` (sheet frame): the button there changes the note; "save", "cancel" or "keyboard" come back
## for VrMap to act on; "" otherwise (nothing there, or a change made here).
func click(p: Variant) -> String:
	if not is_open():
		return ""
	var id := _button_at(p)
	match id:
		"sym-", "sym+":
			symbol = posmod(symbol + (1 if id == "sym+" else -1), symbols.size())
		"col-", "col+":
			color = posmod(color + (1 if id == "col+" else -1), colors.size())
		"danger":
			danger = not danger
		"rad-", "rad+":
			radius = clampi(radius + (1 if id == "rad+" else -1), 0, max_radius)
		"save", "cancel":
			return id
		"keyboard":
			return id if keyboard else ""
		_:
			if id.begins_with("w:"):
				var w := id.substr(2)
				if words.has(w):
					words.erase(w)
				elif words.size() < MAX_WORDS:
					words.append(w)
	_paint()
	return ""


func _button_at(p: Variant) -> String:
	if not is_open() or not p is Vector3:
		return ""
	var at := Vector2((p as Vector3).x, (p as Vector3).y)
	for b in _buttons:
		if (b["rect"] as Rect2).has_point(at) and _shown(b["id"]):
			return b["id"]
	return ""


func _shown(id: String) -> bool:
	return (id != "keyboard" or keyboard) and (not id.begins_with("rad") or danger)


func _paint() -> void:
	_symbol.text = "Symbol: " + symbols[symbol]
	_color.text = "Colour: " + str(labels.get(colors[color], colors[color]))
	_color.modulate = tints.get(colors[color], INK)
	_radius.text = "Radius %d" % radius
	_radius.visible = danger
	var t := text()
	_text.text = ("Text: " + t.left(MAX_SHOWN)) if not t.is_empty() else "Text: (pick words)"
	for b in _buttons:
		var id: String = b["id"]
		var l: Label3D = b["label"]
		l.visible = _shown(id)
		var picked := id.begins_with("w:") and words.has(id.substr(2))
		l.modulate = HOVER if id == hover else (ON if picked or (id == "danger" and danger) else INK)
		if id.begins_with("w:"):
			l.text = ("%d %s" % [words.find(id.substr(2)) + 1, id.substr(2)]) if picked else id.substr(2)


func _button(id: String, t: String, at: Vector2) -> void:
	var l := _label(at)
	l.text = t
	_buttons.append({"id": id, "rect": Rect2(at - BUTTON_M * 0.5, BUTTON_M), "label": l})


func _label(at: Vector2) -> Label3D:
	var l := Label3D.new()
	l.position = Vector3(at.x, at.y, 0.001)
	l.pixel_size = 0.0003
	l.font_size = 32
	l.outline_size = 8
	l.modulate = INK
	l.render_priority = PRIORITY + 2
	l.outline_render_priority = PRIORITY + 1
	l.shaded = false
	l.double_sided = false
	add_child(l)
	return l
