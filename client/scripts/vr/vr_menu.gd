class_name VrMenu
extends Node3D
## The in-headset VR settings (VrSettings.ROWS), opened with the left menu button. A panel of Label3D lines
## that stands in front of the head when opened. Stick up/down picks a line, left/right or the trigger
## changes it; the main hand's laser pointer (VrRig.update_pointer) picks the line under its dot and its
## trigger changes it (numbers: left half down, right half up). It changes `settings` in place (the rig reads
## it every frame); action rows (VrSettings.ACTIONS) emit `action` instead. Tests drive `nav`, `click`,
## `hover` and `click_at`.
## K7: a second page, "Cheats" (VrCheats rows: the testing cheats, auto-pause, the test kit), reached by a
## "Cheats >" row at the bottom of the settings page, shown only when `cheats_allowed` (--test / --cheats, set by
## the rig) and `cheats_backend` can do cheats. Same input; stick left or "< Back" returns. What it shows is read
## from the backend on each refresh (on open, after a press, on its cheats_changed), never kept as truth.

## An action row was pressed (stick right, trigger, or the pointer's trigger).
signal action(key: String)
## A cheat row was refused (no running game, or the sim said no): the rig buzzes the main hand.
signal cheat_refused(reason: String)

const DIST := 0.9
const LINE_H := 0.042
const WIDTH := 0.78
const PIXEL := 0.0009
const FONT := 32
const SMALL_FONT := 24   # the cheats page's warning and status lines
const ON := 0.7
const OFF := 0.3
const HELP := "point + trigger, or stick: pick / change   menu: close"
const CHEAT_HELP := "point + trigger, or stick right: use   stick left: back"
const CHEAT_WARNING := "Testing cheats: they stay with the character in its save."
const STATUS_MAX := 60
const PICKED := Color(1.0, 0.85, 0.3)
const GREY := Color(0.55, 0.55, 0.55)
const SETTINGS_PAGE := "settings"
const CHEATS_PAGE := "cheats"
const CHEATS_ROW := "#cheats"   # the settings page's "Cheats >" row
const BACK_ROW := "#back"       # the cheats page's "< Back" row

var settings: Dictionary
var row := 0
var page := SETTINGS_PAGE
## The Cheats page may show (VrRig.cheats_allowed: --test / --cheats).
var cheats_allowed := false
## Who the Cheats page talks to (VrRig.cheats_backend: the LiveSession; null in the mock).
var cheats_backend: Object:
	set(b):
		if is_instance_valid(cheats_backend) and cheats_backend.has_signal("cheats_changed") \
				and cheats_backend.is_connected("cheats_changed", _on_cheats_changed):
			cheats_backend.disconnect("cheats_changed", _on_cheats_changed)
		cheats_backend = b
		if is_instance_valid(b) and b.has_signal("cheats_changed") and not b.is_connected("cheats_changed", _on_cheats_changed):
			b.connect("cheats_changed", _on_cheats_changed)
## The cheats page's rows as last read (what is on the panel; VrCheats.use reads the backend again).
var cheat_rows: Array[Dictionary] = []
var status := ""          # the cheats page's status line: what the last press did
var status_warn := false
var refreshes := 0        # cheats page reads (tests count them)
var _armed := true
var _hover := -1          # row under the pointer last frame (-1: none)
var _lines: Array[Label3D] = []
var _quad: QuadMesh
var _back: MeshInstance3D


func _init(s: Dictionary) -> void:
	settings = s
	name = "VrMenu"
	_back = MeshInstance3D.new()
	_quad = QuadMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.05, 0.06, 0.08, 0.85)
	mat.no_depth_test = true
	mat.render_priority = 110
	_quad.material = mat
	_back.mesh = _quad
	add_child(_back)
	refresh()


## Title, the settings rows, help (the settings page without its "Cheats >" row).
static func _line_count() -> int:
	return VrSettings.ROWS.size() + 2


static func _panel_h(lines := 0) -> float:
	return (lines if lines > 0 else _line_count()) * LINE_H + 0.05


static func _panel_cy(lines := 0) -> float:
	return -((lines if lines > 0 else _line_count()) - 1) * LINE_H * 0.5


## The row (index into the page's rows) at a point on the panel (menu space, the plane z = 0), -1 when the
## point is on the title, the lines after the rows or off the panel. `rows`: the page's row count (default: the
## settings page without its "Cheats >" row).
static func row_at(p: Vector3, rows := -1) -> int:
	var n := rows if rows >= 0 else VrSettings.ROWS.size()
	if not p.is_finite() or absf(p.x) > WIDTH * 0.5:
		return -1
	var line := roundi(-p.y / LINE_H)
	return line - 1 if line >= 1 and line <= n else -1


## True when a point (menu space) is on a panel of `lines` lines (default: the settings page without "Cheats >").
static func on_panel(p: Vector3, lines := 0) -> bool:
	return p.is_finite() and absf(p.x) <= WIDTH * 0.5 and absf(p.y - _panel_cy(lines)) <= _panel_h(lines) * 0.5


## The settings page has its "Cheats >" row: allowed, and the backend can do cheats.
func cheats_shown() -> bool:
	return cheats_allowed and VrCheats.available(cheats_backend)


## Rows on the page now.
func row_count() -> int:
	if page == CHEATS_PAGE:
		return 1 + cheat_rows.size()
	return VrSettings.ROWS.size() + (1 if cheats_shown() else 0)


## Lines on the page now: title, rows, (cheats page: warning, status), help.
func line_count() -> int:
	return 1 + row_count() + (2 if page == CHEATS_PAGE else 0) + 1


## The row of this page under a point (menu space), -1 for none.
func row_under(p: Variant) -> int:
	return row_at(p, row_count()) if p is Vector3 else -1


## A point (menu space) is on this page's panel.
func covers(p: Variant) -> bool:
	return p is Vector3 and on_panel(p, line_count())


## The key of row i on this page: a VrSettings key, CHEATS_ROW, BACK_ROW or a VrCheats key; "" for none.
func key_of(i: int) -> String:
	if page == CHEATS_PAGE:
		if i == 0:
			return BACK_ROW
		return str(cheat_rows[i - 1]["key"]) if i >= 1 and i <= cheat_rows.size() else ""
	if i >= 0 and i < VrSettings.ROWS.size():
		return VrSettings.ROWS[i][0]
	return CHEATS_ROW if i == VrSettings.ROWS.size() and cheats_shown() else ""


## Stands DIST in front of `head` (rig-space transform), level, facing it.
func place(head: Transform3D) -> void:
	var fwd := -head.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var at := head.origin + fwd * DIST + Vector3(0, 0.12, 0)
	transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), at)   # its +Z (the text side) faces the head


## A stick: pick and change lines on each push past ON (back inside OFF arms the next one). True if a value
## changed.
func nav(v: Vector2) -> bool:
	var changed := false
	if _armed and absf(v.y) > ON and absf(v.y) >= absf(v.x):
		row = wrapi(row - int(signf(v.y)), 0, row_count())
		_armed = false
	elif _armed and absf(v.x) > ON:
		changed = change(int(signf(v.x)))
		_armed = false
	elif v.length() < OFF:
		_armed = true
	_show_page()
	return changed


func click() -> bool:
	return change(1)


## The pointer's dot (menu space) or null when it is off the panel: the row under it is picked when the dot
## moves onto it, so the sticks still pick rows while the pointer rests.
func hover(p: Variant) -> void:
	var r := row_under(p)
	if r == _hover:
		return
	_hover = r
	if r >= 0:
		row = r
		_show_page()


## The pointer's trigger at `p` (menu space): picks the row under it and changes it, numbers down on the left
## half and up on the right half, everything else forward. True if a value changed (or an action ran).
func click_at(p: Vector3) -> bool:
	var r := row_under(p)
	if r < 0:
		return false
	row = r
	_hover = r
	var key := key_of(r)
	return change(-1 if page == SETTINGS_PAGE and VrSettings.is_number(key) and p.x < 0.0 else 1)


## Changes the picked row by `dir`. True when a setting changed (or a settings action ran); page switches and
## cheat rows return false (they change no setting).
func change(dir: int) -> bool:
	var key := key_of(row)
	if page == CHEATS_PAGE:
		if dir < 0 or key == BACK_ROW:
			open_page(SETTINGS_PAGE)
		elif not key.is_empty():
			_use_cheat(key)
		return false
	if key == CHEATS_ROW:
		if dir > 0:
			open_page(CHEATS_PAGE)
		return false
	if key.is_empty():
		return false
	if VrSettings.ACTIONS.has(key):
		if dir > 0:
			action.emit(key)
		refresh()
		return dir > 0
	var v: Variant = VrSettings.step(settings, key, dir)
	if v == settings.get(key):
		return false
	settings[key] = v
	refresh()
	return true


## Shows a page from its first row ("< Back" on the cheats page; back on the settings page, "Cheats >").
func open_page(p: String) -> void:
	page = CHEATS_PAGE if p == CHEATS_PAGE and cheats_shown() else SETTINGS_PAGE
	row = 0 if page == CHEATS_PAGE else (VrSettings.ROWS.size() if cheats_shown() else 0)
	_hover = -1
	status = ""
	status_warn = false
	refresh()


## Reads the page again (the cheats page asks the backend) and redraws it. Leaves the cheats page when it may no
## longer show.
func refresh() -> void:
	if page == CHEATS_PAGE and not cheats_shown():
		page = SETTINGS_PAGE
		row = 0
		_hover = -1
	if page == CHEATS_PAGE:
		cheat_rows = VrCheats.read(cheats_backend)
		refreshes += 1
	else:
		cheat_rows = []
	row = clampi(row, 0, maxi(row_count() - 1, 0))
	_show_page()


## The backend's cheats_changed: the sim applied a change (here or elsewhere).
func _on_cheats_changed(_c: Variant = null) -> void:
	if visible and page == CHEATS_PAGE:
		refresh()


func _use_cheat(key: String) -> void:
	var r := VrCheats.use(cheats_backend, key)
	status = str(r.get("text", "")).left(STATUS_MAX)
	status_warn = r.get("ok") != true
	refresh()
	if status_warn:
		cheat_refused.emit(status)


## Lines as the page has them: [text, colour, font size] each.
func page_lines() -> Array:
	var out: Array = []
	if page == CHEATS_PAGE:
		out.append(["Cheats", Color.WHITE, FONT])
		out.append([_mark(0) + "< Back", PICKED if row == 0 else Color.WHITE, FONT])
		for i in cheat_rows.size():
			var c: Dictionary = cheat_rows[i]
			var value := "press" if c.get("kind") == VrCheats.ACTION else ("on" if c.get("on") == true else "off")
			var col := PICKED if row == i + 1 else Color.WHITE
			if c.get("enabled") != true:
				col = col.lerp(GREY, 0.6)
			out.append(["%s %s:  %s" % [_mark(i + 1), str(c.get("label", "")).left(VrCheats.LABEL_MAX), value], col, FONT])
		out.append([CHEAT_WARNING, VrCheats.WARN, SMALL_FONT])
		var live: bool = not cheat_rows.is_empty() and cheat_rows[0].get("enabled") == true
		var st := status if not status.is_empty() else ("" if live else "Cheats need a running game.")
		out.append([st, Color(1.0, 0.55, 0.5) if status_warn or not live else Color.WHITE, SMALL_FONT])
		out.append([CHEAT_HELP, Color(0.7, 0.7, 0.7), FONT])
		return out
	out.append(["VR settings", Color.WHITE, FONT])
	for i in VrSettings.ROWS.size():
		var r: Array = VrSettings.ROWS[i]
		out.append(["%s %s:  %s" % [_mark(i), r[1], VrSettings.label(r[0], settings.get(r[0]))],
				PICKED if i == row else Color.WHITE, FONT])
	if cheats_shown():
		var i := VrSettings.ROWS.size()
		out.append(["%s Cheats >" % _mark(i), PICKED if i == row else VrCheats.WARN, FONT])
	out.append([HELP, Color(0.7, 0.7, 0.7), FONT])
	return out


func _mark(i: int) -> String:
	return ">" if i == row else "  "


## Draws page_lines (no backend reads) and sizes the panel to them.
func _show_page() -> void:
	var lines := page_lines()
	while _lines.size() < lines.size():
		var l := Label3D.new()
		l.pixel_size = PIXEL
		l.font_size = FONT
		l.outline_size = 0
		l.no_depth_test = true
		l.render_priority = 111
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		l.position = Vector3(-0.37, -_lines.size() * LINE_H, 0)
		add_child(l)
		_lines.append(l)
	for i in _lines.size():
		var l := _lines[i]
		l.visible = i < lines.size()
		if l.visible:
			l.text = lines[i][0]
			l.modulate = lines[i][1]
			l.font_size = lines[i][2]
	_quad.size = Vector2(WIDTH, _panel_h(lines.size()))
	_back.position = Vector3(0, _panel_cy(lines.size()), -0.002)


## The texts of the lines that show, in order (tests read them).
func texts() -> PackedStringArray:
	var out := PackedStringArray()
	for l in _lines:
		if l.visible:
			out.append(l.text)
	return out
