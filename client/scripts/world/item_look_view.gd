class_name ItemLookView
extends Node3D
## Live item state on the 3D items lying in the world (block "Live item tiles"; values and colours: ItemLook):
## frost on cold and frozen items, a heat shimmer on hot ones, a spoilage tint on food going off, and the
## liquid in a see-through container up to its level, grime on a fouled gun. Each such item near `focus` gets a
## thin see-through shell over its own mesh (its model's meshes, or its placeholder's box) with
## shaders/item_state.gdshader, plus GunGrime's shells under those meshes for a fouled gun (lying guns are drawn
## as shared multimeshes, so the grime can't go on the gun's own meshes); items with nothing to show get none,
## so the cost is only for the few that have a state.
## States come from the snapshot (`player.item_states`, Snapshot.item_states: carried items and those lying in
## the player's reach) through set_states; where an item lies, and whether it is shown (not in a hand, its
## drawer open), from WorldView.item_slot, so carried items get no shell here. Shells follow their items every
## frame (a drawer pulled out carries them) and are picked again a few times a second.

const MAX_SHELLS := 64       # nearest items with a state that get a shell
const PICK_EVERY_S := 0.25   # how often the nearest are picked again
const COLD_FROST := 0.35     # frost strength on a cold (not frozen) item
const LIQUID_ALPHA := 0.6    # how much a see-through container's liquid shows

## Snapshot index: [temp, rot, fill, fill_type, see_through, fill_ml, dirt] (after the uid; contracts/snapshot.md).
enum { S_TEMP, S_ROT, S_FILL, S_TYPE, S_SEE, S_ML, S_DIRT, S_SIZE }

static var _shader: Shader

var world: WorldView
## Where the player is (world space): shells go to the items nearest to it.
var focus := Vector3.ZERO
var _states := {}      # uid -> PackedInt32Array (S_SIZE), only items with something to show
var _shells := {}      # uid -> Node3D (its MeshInstance3D children share one ShaderMaterial)
var _pick_in := 0.0


## Takes a snapshot's item states, with the player's square as the focus.
func apply(snap: Snapshot) -> void:
	if world != null:
		focus = world.coords.ms_center_to_world(snap.player_pos)
	set_states(snap.item_states)


## Replaces the item states (uid -> PackedInt32Array of S_SIZE, values as the snapshot sends them; anything
## malformed is left out). Only items with something to show are kept.
func set_states(states: Dictionary) -> void:
	_states.clear()
	for uid: Variant in states:
		var s: Variant = states[uid]
		if uid is int and s is PackedInt32Array and (s as PackedInt32Array).size() == S_SIZE and shows(s):
			_states[uid] = s
	_pick_in = 0.0


## Whether a state has anything to show on a 3D item: cold, frozen or hot, rot past ItemLook.TINT_FROM, or a
## see-through container holding some liquid, or a fouled gun.
static func shows(s: PackedInt32Array) -> bool:
	return ItemLook.temp_of(s[S_TEMP]) != ItemLook.Temp.NORMAL or ItemLook.rot_strength(ItemLook.rot_of(s[S_ROT])) > 0.0 \
			or (s[S_SEE] == 1 and ItemLook.level(s[S_FILL]) > 0.0) or grime_of(s) > 0.0


## A gun's fouling as grime 0..1 (GunGrime, the held gun's mapping); 0 for a clean gun or anything else.
static func grime_of(s: PackedInt32Array) -> float:
	return GunGrime.grime_for(ItemLook.dirt_of(s[S_DIRT]))


func shell_count() -> int:
	return _shells.size()


## The shell of item `uid` (tests), or null.
func shell(uid: int) -> Node3D:
	return _shells.get(uid)


func _process(delta: float) -> void:
	tick(delta)


## Picks the nearest items again when due, then moves every shell onto its item (tests call it directly).
func tick(delta: float) -> void:
	_pick_in -= delta
	if _pick_in <= 0.0:
		_pick_in = PICK_EVERY_S
		_pick()
	for uid: int in _shells.keys():
		var slot: Array = world.item_slot(uid) if world != null else []
		var sh: Node3D = _shells[uid]
		sh.visible = not slot.is_empty()
		if sh.visible:
			_place(sh, slot)


func _pick() -> void:
	var near := []   # [distance², uid, slot]
	if world != null:
		for uid: int in _states:
			var slot: Array = world.item_slot(uid)
			if not slot.is_empty():
				near.append([(slot[3] as Vector3).distance_squared_to(focus), uid, slot])
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var keep := {}
	for k in mini(near.size(), MAX_SHELLS):
		var uid: int = near[k][1]
		var slot: Array = near[k][2]
		var sh: Node3D = _shells.get(uid)
		if sh == null or sh.get_meta(&"itype", -1) != slot[1]:
			if sh != null:
				sh.free()
			sh = make_shell(world.props.item(slot[1]) if world.props != null else null, slot[1])
			sh.name = "look_%d" % uid
			sh.set_meta(&"itype", slot[1])
			add_child(sh)
			_shells[uid] = sh
		paint(sh, _states[uid], ItemLook.liquid_color(world.tables.def_at("itype", _states[uid][S_TYPE])
				if world.tables != null and _states[uid][S_TYPE] > 0 else null))
		keep[uid] = true
	for uid: int in _shells.keys():
		if not keep.has(uid):
			(_shells[uid] as Node3D).free()
			_shells.erase(uid)


## Puts a shell on its item (slot from WorldView.item_slot) and sets the liquid's surface height.
func _place(sh: Node3D, slot: Array) -> void:
	var xf: Transform3D = slot[4]
	sh.transform = xf
	var box: AABB = sh.get_meta(&"box", AABB())
	var wb := xf * box
	var mat := sh.get_meta(&"mat") as ShaderMaterial
	var lv: float = sh.get_meta(&"level", 0.0)
	mat.set_shader_parameter(&"level_y", wb.position.y + wb.size.y * lv if lv > 0.0 else -100000.0)


## A shell for an item drawn as `prop` (its model's meshes, else its placeholder's box): a Node3D whose meshes
## share one ShaderMaterial (meta "mat"; its item-space box in meta "box"). Also for an item held in a hand:
## put it under the item's node with an identity transform, paint it, and set_level_y as it moves.
static func make_shell(prop: PropCatalog.Prop, itype: int) -> Node3D:
	if _shader == null:
		_shader = load("res://shaders/item_state.gdshader")
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.render_priority = WorldLighting.UNDER_PRIORITY   # darkened by the light pass, like the item under it
	mat.set_shader_parameter(&"frost_color", ItemLook.FROST)
	mat.set_shader_parameter(&"heat_color", ItemLook.HEAT)
	var sh := Node3D.new()
	sh.set_meta(&"mat", mat)
	var box := PropMesher.item_box(prop, itype) if prop != null else PropMesher.ITEM_BOX_OTHER
	sh.set_meta(&"box", box)
	if prop != null and prop.model != null:
		for p: Array in prop.model.parts:
			var mi := MeshInstance3D.new()
			mi.mesh = p[0]
			mi.transform = p[1]
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			sh.add_child(mi)
	else:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = box.size
		mi.mesh = bm
		mi.position = box.get_center()
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sh.add_child(mi)
	return sh


## Sets a shell's look from a state (S_SIZE values as the snapshot sends them) and the liquid's colour.
static func paint(sh: Node3D, s: PackedInt32Array, liquid: Color) -> void:
	var mat := sh.get_meta(&"mat") as ShaderMaterial
	var temp := ItemLook.temp_of(s[S_TEMP])
	mat.set_shader_parameter(&"frost", 1.0 if temp == ItemLook.Temp.FROZEN else (COLD_FROST if temp == ItemLook.Temp.COLD else 0.0))
	mat.set_shader_parameter(&"heat", 1.0 if temp == ItemLook.Temp.HOT else 0.0)
	mat.set_shader_parameter(&"tint", ItemLook.rot_tint(ItemLook.rot_of(s[S_ROT])))
	var lv := ItemLook.level(s[S_FILL]) if s[S_SEE] == 1 else 0.0
	sh.set_meta(&"level", lv)
	mat.set_shader_parameter(&"liquid", Color(liquid.r, liquid.g, liquid.b, LIQUID_ALPHA if lv > 0.0 else 0.0))
	GunGrime.apply(sh, grime_of(s))   # a grime shell under each of the shell's meshes; none when clean


## For a shell that isn't placed by this view (in a hand): the liquid's surface from the shell's place now.
static func set_level_y(sh: Node3D) -> void:
	var wb := sh.global_transform * (sh.get_meta(&"box", AABB()) as AABB)
	var lv: float = sh.get_meta(&"level", 0.0)
	(sh.get_meta(&"mat") as ShaderMaterial).set_shader_parameter(&"level_y",
			wb.position.y + wb.size.y * lv if lv > 0.0 else -100000.0)
