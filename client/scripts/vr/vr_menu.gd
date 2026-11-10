class_name VrMenu
extends Node3D
## The in-headset VR settings (VrSettings.ROWS), opened with the left menu button. A panel of Label3D lines
## that stands in front of the head when opened. Stick up/down picks a line, left/right or the trigger
## changes it; the main hand's laser pointer (VrRig.update_pointer) picks the line under its dot and its
## trigger changes it (numbers: left half down, right half up). It changes `settings` in place (the rig reads
## it every frame); action rows (VrSettings.ACTIONS) emit `action` instead. Tests drive `nav`, `click`,
## `hover` and `click_at`.

## An action row was pressed (stick right, trigger, or the pointer's trigger).
signal action(key: String)

const DIST := 0.9
const LINE_H := 0.042
const WIDTH := 0.78
const PIXEL := 0.0009
const ON := 0.7
const OFF := 0.3
const HELP := "point + trigger, or stick: pick / change   menu: close"

var settings: Dictionary
var row := 0
var _armed := true
var _hover := -1          # row under the pointer last frame (-1: none)
var _lines: Array[Label3D] = []


func _init(s: Dictionary) -> void:
	settings = s
	name = "VrMenu"
	var n := _line_count()
	var back := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(WIDTH, _panel_h())
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.05, 0.06, 0.08, 0.85)
	mat.no_depth_test = true
	mat.render_priority = 110
	quad.material = mat
	back.mesh = quad
	back.position = Vector3(0, _panel_cy(), -0.002)
	add_child(back)
	for i in n:
		var l := Label3D.new()
		l.pixel_size = PIXEL
		l.font_size = 32
		l.outline_size = 0
		l.no_depth_test = true
		l.render_priority = 111
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		l.position = Vector3(-0.37, -i * LINE_H, 0)
		add_child(l)
		_lines.append(l)
	_lines[0].text = "VR settings"
	_lines[-1].text = HELP
	_lines[-1].modulate = Color(0.7, 0.7, 0.7)
	refresh()


## Title, the rows, help.
static func _line_count() -> int:
	return VrSettings.ROWS.size() + 2


static func _panel_h() -> float:
	return _line_count() * LINE_H + 0.05


static func _panel_cy() -> float:
	return -(_line_count() - 1) * LINE_H * 0.5


## The row (index into VrSettings.ROWS) at a point on the panel (menu space, the plane z = 0), -1 when the
## point is on the title, the help line or off the panel.
static func row_at(p: Vector3) -> int:
	if not p.is_finite() or absf(p.x) > WIDTH * 0.5:
		return -1
	var line := roundi(-p.y / LINE_H)
	return line - 1 if line >= 1 and line <= VrSettings.ROWS.size() else -1


## True when a point (menu space) is on the panel.
static func on_panel(p: Vector3) -> bool:
	return p.is_finite() and absf(p.x) <= WIDTH * 0.5 and absf(p.y - _panel_cy()) <= _panel_h() * 0.5


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
		row = wrapi(row - int(signf(v.y)), 0, VrSettings.ROWS.size())
		_armed = false
	elif _armed and absf(v.x) > ON:
		changed = change(int(signf(v.x)))
		_armed = false
	elif v.length() < OFF:
		_armed = true
	refresh()
	return changed


func click() -> bool:
	return change(1)


## The pointer's dot (menu space) or null when it is off the panel: the row under it is picked when the dot
## moves onto it, so the sticks still pick rows while the pointer rests.
func hover(p: Variant) -> void:
	var r := row_at(p) if p is Vector3 else -1
	if r == _hover:
		return
	_hover = r
	if r >= 0:
		row = r
		refresh()


## The pointer's trigger at `p` (menu space): picks the row under it and changes it, numbers down on the left
## half and up on the right half, everything else forward. True if a value changed (or an action ran).
func click_at(p: Vector3) -> bool:
	var r := row_at(p)
	if r < 0:
		return false
	row = r
	_hover = r
	var key: String = VrSettings.ROWS[r][0]
	return change(-1 if VrSettings.is_number(key) and p.x < 0.0 else 1)


func change(dir: int) -> bool:
	var key: String = VrSettings.ROWS[row][0]
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


func refresh() -> void:
	for i in VrSettings.ROWS.size():
		var r: Array = VrSettings.ROWS[i]
		var l := _lines[i + 1]
		l.text = "%s %s:  %s" % [">" if i == row else "  ", r[1], VrSettings.label(r[0], settings.get(r[0]))]
		l.modulate = Color(1.0, 0.85, 0.3) if i == row else Color.WHITE
