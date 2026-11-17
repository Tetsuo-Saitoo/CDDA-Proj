class_name VrFire
extends Node3D
## Block L9, VR: lighting and putting out a fire by hand, through `backend` (LiveSession's light_fire /
## extinguish_fire: the bridge's `light` / `extinguish` ops; CDDA decides, its questions stay its popups). A hand
## low over a square (in its footprint, at most UP_M over its floor) on the player's level:
## - a heat square (Snapshot.heat_at: a fire, or furniture like a fireplace or wood stove; never a vehicle's, which has
##   no switch) with a fire burning, the player's square or one next to it: the trigger puts it out (CDDA's
##   "Extinguish fire": only a fire in fire furniture; elsewhere CDDA says no);
## - one with no fire burning, next to the player: the trigger lights it, with the item the hand holds when the
##   player carries it (a lighter, matches; CDDA says no to anything else), else CDDA's pick of what the player carries;
## - a square without heat but with something lying on it (fuel), next to the player, while the hand holds a carried
##   item: the trigger lights it with that item (a campfire: drop the fuel there first).
## While a hand is on such a square a short line by it says what the trigger does (update). One square gets at most
## one op per PRESS_S. Everything here comes from the snapshot and the hands; LiveSession checks every op again.

const UP_M := 1.2           # the hand at most this high over the square's floor ...
const DOWN_M := 0.2         # ... and at most this far under it
const PRESS_S := 1.0        # one op a square this often at most
const NAME_MAX := 24        # characters of an item name in the line
const HINT_UP := 0.1        # the line this far over the hand
const LIGHT := "light"
const EXTINGUISH := "extinguish"

var world: WorldView
## LiveSession (VrRig passes its cook backend; null in the mock): light_fire / extinguish_fire, looked up by name.
var backend: Object = null
var hints: Array[Label3D] = [null, null]   # the line by each hand
var sent := 0               # ops the backend took (tests)
var _last := {}             # square -> clock of its last op
var _clock := 0.0


func _init() -> void:
	name = "VrFire"


## The backend can light and put out fires.
func can_fire() -> bool:
	return is_instance_valid(backend) and backend.has_method("light_fire") and backend.has_method("extinguish_fire")


## What the trigger would do with a hand at `pt` (world) holding `held` (an ItemRef, or null): {op (LIGHT /
## EXTINGUISH), pos, item (the carried ItemRef to light with, or null: CDDA's pick), text}; {} nothing.
func target_at(pt: Vector3, held: Variant) -> Dictionary:
	var snap: Snapshot = world.snapshot if world != null else null
	if snap == null or not pt.is_finite() or not can_fire():
		return {}
	var sq := world.coords.world_to_ms(pt)
	var me := snap.player_pos
	if sq.z != me.z:
		return {}
	var up := pt.y - world.coords.ms_center_to_world(sq).y
	if up < -DOWN_M or up > UP_M:
		return {}
	var d := maxi(absi(sq.x - me.x), absi(sq.y - me.y))
	var it: ItemRef = held if held is ItemRef and (held as ItemRef).carried and (held as ItemRef).uid > 0 else null
	var tables: IdTables = world.tables
	var heat := snap.heat_at(sq)
	if not heat.is_empty():
		var src: int = heat.get("source", -1)
		if src != Snapshot.HEAT_FIRE and src != Snapshot.HEAT_FURNITURE:
			return {}
		if int(heat.get("fire", 0)) > 0:
			return {"op": EXTINGUISH, "pos": sq, "item": null, "text": "trigger: put the fire out"} if d <= 1 else {}
		if d != 1:
			return {}
		return {"op": LIGHT, "pos": sq, "item": it, "text": _light_text(it, tables, "trigger: light the fire")}
	if d != 1 or it == null or not has_items(snap, sq):
		return {}
	return {"op": LIGHT, "pos": sq, "item": it, "text": _light_text(it, tables, "trigger: light a fire here")}


## The trigger with a hand at `pt` holding `held`: "" nothing to do there, LIGHT / EXTINGUISH sent, "wait" (that
## square had one less than PRESS_S ago), "refused" (the backend said no; nothing sent).
func press(pt: Vector3, held: Variant) -> String:
	var t := target_at(pt, held)
	if t.is_empty():
		return ""
	var sq: Vector3i = t["pos"]
	if _clock < float(_last.get(sq, -INF)) + PRESS_S:
		return "wait"
	var me := world.snapshot.player_pos
	var ok: Variant = false
	if t["op"] == EXTINGUISH:
		ok = backend.call("extinguish_fire", sq, me)
	elif t["item"] != null:
		var it: ItemRef = t["item"]
		ok = backend.call("light_fire", sq, me, float(it.uid), float(it.type))
	else:
		ok = backend.call("light_fire", sq, me)
	if not (ok is bool and ok):
		return "refused"
	_last[sq] = _clock
	sent += 1
	return t["op"]


## Every frame (VrRig): the line by hand i over what its trigger would do there (`pts[i]`, `helds[i]`); none when
## not `allowed` (a menu or panel up, no snapshot).
func update(delta: float, pts: Array, helds: Array, allowed := true) -> void:
	if is_finite(delta) and delta > 0.0:
		_clock += delta
	for sq: Vector3i in _last.keys():
		if _clock >= float(_last[sq]) + PRESS_S:
			_last.erase(sq)
	for i in 2:
		var t := {}
		var pt: Variant = pts[i] if i < pts.size() else null
		if allowed and pt is Vector3:
			t = target_at(pt, helds[i] if i < helds.size() else null)
		if t.is_empty():
			if hints[i] != null:
				hints[i].visible = false
			continue
		var l := _hint(i)
		l.position = (pt as Vector3) + Vector3(0.0, HINT_UP, 0.0)   # top_level: in the world
		if l.text != t["text"]:
			l.text = t["text"]
		l.visible = true


## Something lies on square `sq` (the snapshot's item handles there).
static func has_items(snap: Snapshot, sq: Vector3i) -> bool:
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(sq))
	if sm == null:
		return false
	var l := CddaCoords.ms_to_local(sq)
	var tile := l.y * CddaCoords.SEEX + l.x
	for j in range(0, sm.handles.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if sm.handles[j] == tile:
			return true
	return false


static func _light_text(it: ItemRef, tables: IdTables, plain: String) -> String:
	if it == null:
		return plain
	var nm := VrCook._item_name(it.type, tables).left(NAME_MAX)
	return "trigger: light it with " + (nm if not nm.is_empty() else "what you hold")


func _hint(i: int) -> Label3D:
	if hints[i] != null and is_instance_valid(hints[i]):
		return hints[i]
	var l := Label3D.new()
	l.name = "FireHint"
	l.top_level = true
	l.pixel_size = 0.0003
	l.font_size = 32
	l.outline_size = 8
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.render_priority = 5
	l.modulate = Color(1.0, 0.82, 0.45)
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(l)
	hints[i] = l
	return l
