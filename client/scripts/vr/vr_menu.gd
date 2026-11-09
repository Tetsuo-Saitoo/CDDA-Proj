class_name VrMenu
extends Node3D
## The in-headset VR settings (VrSettings.ROWS), opened with the left menu button. A panel of Label3D lines
## that stands in front of the head when opened. Stick up/down picks a line, left/right or the trigger
## changes it; it changes `settings` in place (the rig reads it every frame). Tests drive `nav` and `click`.

const DIST := 0.9
const LINE_H := 0.042
const PIXEL := 0.0009
const ON := 0.7
const OFF := 0.3
const HELP := "stick up/down: pick   left/right or trigger: change   menu: close"

var settings: Dictionary
var row := 0
var _armed := true
var _lines: Array[Label3D] = []


func _init(s: Dictionary) -> void:
	settings = s
	name = "VrMenu"
	var n := VrSettings.ROWS.size() + 2
	var back := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.78, n * LINE_H + 0.05)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.05, 0.06, 0.08, 0.85)
	mat.no_depth_test = true
	mat.render_priority = 110
	quad.material = mat
	back.mesh = quad
	back.position = Vector3(0, -(n - 1) * LINE_H * 0.5, -0.002)
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


func change(dir: int) -> bool:
	var key: String = VrSettings.ROWS[row][0]
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
