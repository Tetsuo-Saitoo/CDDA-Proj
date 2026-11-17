class_name VrWheel
extends Node3D
## Radial context menus in VR (TASKS "Radial context menus"; the wheel itself is lead-ui's RadialRequestWidget). An
## empty hand in a square next to the player (in its footprint, DOWN_M under to UP_M over its floor) that holds
## furniture, or terrain with an examine action (as ContextPrompt names them; with examine ids in the tables, only
## types whose examine does something), uses it with the trigger: `queue_action` sends CDDA's `fp3d_use_<DIR>` for
## that square (what the hands hold used there, else CDDA's examine of it) and RequestUI is asked for a wheel
## (want_wheel, held while that trigger is down).
## - A tap (let go within RadialRequestWidget.TAP_MS of the press) does CDDA's default entry.
## - Held: CDDA's menu shows as a wheel around the hand, where the trigger went down, facing the head: SLOTS sectors
##   in the widget's fixed slots, the default outlined, entries CDDA disables grey. The VR panel stays hidden
##   meanwhile (VrRig: VrPanel.held_back). That hand's stick, or the hand moved off the middle (FLICK_M is the rim),
##   points; letting go of the trigger picks what it points at (RadialRequestWidget.release).
## - Let go pointing at nothing (after the tap time): the wheel stays; a trigger then picks what is pointed at, B / Y
##   (VrRig) cancels.
## A menu that can't be a wheel (RadialRequestWidget.fits), or wheels off (`enabled`, `list_only`: the F1 list
## option), shows on the panel as before. While a free hand is on such a square, a line by it names the object and what the trigger does.
## Only the snapshot, the id tables and RequestUI's own request are read; CDDA decides everything.

const UP_M := 2.0            # the hand at most this high over the square's floor ...
const DOWN_M := 0.2          # ... and at most this far under it
const WAIT_MS := 1500        # CDDA's menu arriving this soon after the press shows as a wheel (main's WHEEL_WAIT_MS)
const RADIUS_M := 0.12       # the wheel's rim
const INNER_M := RADIUS_M * RadialRequestWidget.INNER / RadialRequestWidget.RADIUS   # its dead middle
const FLICK_M := 0.08        # the hand this far off the middle points at the rim
const STICK_ON := 0.5        # a stick past this points
const MOVE_M := 0.02         # after the stick pointed, the hand moving this far points again
const HINT_UP := 0.1         # the line this far over the hand
const NAME_MAX := 32
const LABEL_MAX := 18
## Steps from the player to the square -> CDDA's direction word (main.gd's OCT_ACTIONS).
const DIRS := {Vector2i(1, 0): "RIGHT", Vector2i(1, 1): "RIGHTDOWN", Vector2i(0, 1): "DOWN",
		Vector2i(-1, 1): "LEFTDOWN", Vector2i(-1, 0): "LEFT", Vector2i(-1, -1): "LEFTUP", Vector2i(0, -1): "UP",
		Vector2i(1, -1): "RIGHTUP"}

var world: WorldView
## RequestUI (main.gd): asked for a wheel (want_wheel) and read for the wheel it shows (its `widget`).
var request_ui: RequestUI
## main.gd: (action: String) -> bool, CDDA's main-loop action queue; false when it can't take one now (no live game).
var queue_action := Callable()
var enabled := true          # false: CDDA's menus stay lists on the panel
## main.gd: () -> bool, true while HudSettings.context_menu is the list option (then as `enabled` false).
var list_only := Callable()
var live := false            # a live game (VrRig.live_stairs): only then is there anything to use
var hints: Array[Label3D] = [null, null]   # the line by each hand
var hand := -1               # the hand whose trigger opened the last wheel: 0 left, 1 right; -1 none
var sent := 0                # actions queued (tests)
var wheel: Node3D            # the wheel's drawing while one is up
var _down: Array[bool] = [false, false]
var _at := Vector3.ZERO      # where that hand was when its trigger went down (world)
var _widget: RadialRequestWidget   # the wheel drawn, null none
var _sectors: Array[MeshInstance3D] = []
var _labels: Array[Label3D] = []
var _painted := -2           # the slot painted as pointed at
var _by_stick := false
var _stick_at := Vector3.ZERO


func _init() -> void:
	name = "VrWheel"


## The furniture (or terrain with an examine action) at square `p` that a hand can use, null none.
static func object_at(snap: Snapshot, tables: IdTables, p: Vector3i) -> IdTables.Def:
	if snap == null or tables == null:
		return null
	var f := ContextPrompt.furn_at(snap, p)
	var d: IdTables.Def = tables.def_at("furn", f) if f > 0 else null
	if d == null and tables.has_examine:
		var t := ContextPrompt.at(snap, p, "ter")
		d = tables.def_at("ter", t) if t > 0 else null
	if d != null and tables.has_examine and d.examine == "":
		return null   # examining it does nothing special
	return d


## What the trigger would use with a free hand at `pt` (world): {pos, action (fp3d_use_<DIR>), name, text}; {} none.
func target_at(pt: Vector3) -> Dictionary:
	var snap: Snapshot = world.snapshot if world != null else null
	if snap == null or world.tables == null or not pt.is_finite():
		return {}
	var sq := world.coords.world_to_ms(pt)
	var me := snap.player_pos
	var step := Vector2i(sq.x - me.x, sq.y - me.y)
	if sq.z != me.z or not DIRS.has(step):
		return {}
	var up := pt.y - world.coords.ms_center_to_world(sq).y
	if up < -DOWN_M or up > UP_M:
		return {}
	var d := object_at(snap, world.tables, sq)
	if d == null:
		return {}
	var nm := CddaText.plain(d.name).strip_edges().left(NAME_MAX)
	if nm.is_empty():
		return {}
	var verb := ContextPrompt.word_for(d.examine, world.tables.has_examine)
	return {"pos": sq, "action": "fp3d_use_" + str(DIRS[step]), "name": nm,
			"text": "%s\ntrigger: %s   hold: choices" % [nm.capitalize(), verb] if wheels() else "%s\ntrigger: %s" % [nm.capitalize(), verb]}


## CDDA's menus may show as wheels: `enabled` and not the list option.
func wheels() -> bool:
	var v: Variant = list_only.call() if list_only.is_valid() else false
	return enabled and not (v is bool and v)


## A wheel is up (RequestUI shows a RadialRequestWidget not yet answered).
func active() -> bool:
	return shown() != null


## The wheel RequestUI shows, null none.
func shown() -> RadialRequestWidget:
	if request_ui == null or not is_instance_valid(request_ui) or not request_ui.visible:
		return null
	var w := request_ui.widget as RadialRequestWidget
	return w if w != null and is_instance_valid(w) and not w.done else null


## Hand i's trigger at `pt` (world), the hand free. A wheel up: picks what it points at (nothing pointed: it stays).
## Else on something to use: sends its fp3d_use and asks for the wheel; true. False: nothing here (or no live game).
func press(i: int, pt: Vector3) -> bool:
	var w := shown()
	if w != null:
		w.pick(w.hovered)
		return true
	if i < 0 or i > 1 or not live or not queue_action.is_valid():
		return false
	var t := target_at(pt)
	if t.is_empty():
		return false
	var ok: Variant = queue_action.call(t["action"])
	if not (ok is bool and ok):
		return false
	sent += 1
	hand = i
	_at = pt
	_down[i] = true
	if wheels() and request_ui != null and is_instance_valid(request_ui):
		request_ui.want_wheel(WAIT_MS, true, func() -> bool: return _down[i])
	return true


## Hand i's trigger let go: a wheel held open picks what it points at (nothing: a tap picks CDDA's default, a longer
## hold leaves it up). True when that trigger had opened one.
func release(i: int) -> bool:
	if i < 0 or i > 1 or not _down[i]:
		return false
	_down[i] = false
	var w := shown()
	if w != null and w.hold:
		w.release()
	return true


## B / Y with a wheel up: cancels CDDA's menu. True if there was one.
func cancel() -> bool:
	var w := shown()
	if w == null:
		return false
	w.cancel()
	return true


## Per frame (the rig): the wheel's drawing and pointing while one is up, else the line by each free hand on
## something to use. `at`: both hands' points (world), `sticks`: their sticks (x right, y up), `free`: hand i holds
## nothing, `head`: the head's pose.
func update(at: Array[Vector3], sticks: Array[Vector2], free: Array[bool], head: Transform3D) -> void:
	var w := shown()
	if w != _widget:
		_build(w, head)
	if w != null:
		_point(w, at, sticks)
		_paint(w)
	for i in 2:
		var t := {} if w != null or i >= at.size() or i >= free.size() or not free[i] or not live else target_at(at[i])
		_hint(i, at[i] if i < at.size() else Vector3.ZERO, str(t.get("text", "")))


## Points `w` where hand `hand`'s stick or its offset from the wheel's middle says.
func _point(w: RadialRequestWidget, at: Array[Vector3], sticks: Array[Vector2]) -> void:
	var i := hand if hand >= 0 and hand < at.size() else -1
	if i < 0 or wheel == null:
		return
	var s := sticks[i] if i < sticks.size() and sticks[i].is_finite() else Vector2.ZERO
	var p := at[i]
	if s.length() >= STICK_ON:
		_by_stick = true
		_stick_at = p
		w.aim(Vector2(s.x, -s.y).normalized() * RadialRequestWidget.RADIUS)
		return
	if not p.is_finite() or (_by_stick and p.distance_to(_stick_at) < MOVE_M):
		return
	_by_stick = false
	var l := wheel.global_transform.affine_inverse() * p
	w.aim(Vector2(l.x, -l.y) / FLICK_M * RadialRequestWidget.RADIUS)


## A new wheel (or none): the old drawing goes; `w`'s is made at the opening hand's point, facing the head.
func _build(w: RadialRequestWidget, head: Transform3D) -> void:
	if wheel != null and is_instance_valid(wheel):
		wheel.queue_free()
	wheel = null
	_sectors.clear()
	_labels.clear()
	_painted = -2
	_by_stick = false
	_widget = w
	if w == null:
		return
	wheel = Node3D.new()
	wheel.name = "Wheel"
	add_child(wheel)
	var o := _at if _at.is_finite() else head.origin - head.basis.z * 0.5
	var z := head.origin - o
	z = z.normalized() if z.length() > 0.01 else Vector3.BACK
	var x := Vector3.UP.cross(z)
	x = x.normalized() if x.length() > 0.01 else Vector3.RIGHT
	wheel.global_transform = Transform3D(Basis(x, z.cross(x), z), o)
	var step := TAU / RadialRequestWidget.SLOTS
	for s in RadialRequestWidget.SLOTS:
		if s == w.default_slot:   # what a tap picks: outlined
			var ring := _sector(s * step, step, RADIUS_M + 0.004, INNER_M - 0.004, RadialRequestWidget.COLOR_TEXT)
			ring.position.z = -0.001
			wheel.add_child(ring)
		var m := _sector(s * step, step, RADIUS_M, INNER_M, RadialRequestWidget.COLOR_EMPTY)
		wheel.add_child(m)
		_sectors.append(m)
		var e: Variant = w.slots[s] if s < w.slots.size() else null
		var l := Label3D.new()
		l.pixel_size = 0.00022
		l.font_size = 32
		l.outline_size = 8
		l.no_depth_test = true
		l.render_priority = 7
		l.double_sided = false
		l.width = 520.0
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var mid := (INNER_M + RADIUS_M) * 0.5
		l.position = Vector3(sin(s * step) * mid, cos(s * step) * mid, 0.002)
		l.text = CddaText.plain(str((e as Dictionary).get("label", ""))).left(LABEL_MAX) if e is Dictionary else ""
		l.modulate = RadialRequestWidget.COLOR_TEXT if e is Dictionary and e.get("enabled") == true \
				else RadialRequestWidget.COLOR_GREY
		wheel.add_child(l)
		_labels.append(l)
	_paint(w)


## Colours each sector: pointed at (and allowed), holding an entry, or empty.
func _paint(w: RadialRequestWidget) -> void:
	if w.hovered == _painted or _sectors.size() != RadialRequestWidget.SLOTS:
		return
	_painted = w.hovered
	for s in RadialRequestWidget.SLOTS:
		var e: Variant = w.slots[s] if s < w.slots.size() else null
		var col := RadialRequestWidget.COLOR_EMPTY
		if e is Dictionary:
			col = RadialRequestWidget.COLOR_HOVER if s == w.hovered and e.get("enabled") == true \
					else RadialRequestWidget.COLOR_SLOT
		(_sectors[s].material_override as StandardMaterial3D).albedo_color = col


## One sector of the wheel: centred on angle `mid` (0 at the top, clockwise as seen from the front), `width` wide,
## from `inner` to `outer` metres, in the wheel's plane.
static func _sector(mid: float, width: float, outer: float, inner: float, col: Color) -> MeshInstance3D:
	var v := PackedVector3Array()
	var n := 8
	for k in n:
		var a0 := mid - width * 0.5 + 0.02 + (width - 0.04) * k / n
		var a1 := mid - width * 0.5 + 0.02 + (width - 0.04) * (k + 1) / n
		var o0 := Vector3(sin(a0), cos(a0), 0) * outer
		var o1 := Vector3(sin(a1), cos(a1), 0) * outer
		var i0 := Vector3(sin(a0), cos(a0), 0) * inner
		var i1 := Vector3(sin(a1), cos(a1), 0) * inner
		v.append_array(PackedVector3Array([i0, o0, o1, i0, o1, i1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = 6
	mat.albedo_color = col
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _hint(i: int, pt: Vector3, text: String) -> void:
	if text.is_empty():
		if hints[i] != null and is_instance_valid(hints[i]):
			hints[i].visible = false
		return
	if hints[i] == null or not is_instance_valid(hints[i]):
		var l := Label3D.new()
		l.name = "WheelHint%d" % i
		l.pixel_size = 0.0003
		l.font_size = 28
		l.outline_size = 8
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.render_priority = 5
		l.width = 700.0
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(l)
		hints[i] = l
	hints[i].text = text
	hints[i].global_position = pt + Vector3.UP * HINT_UP
	hints[i].visible = true
