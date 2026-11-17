class_name VrHeld
extends Node3D
## Live game in VR: what one hand holds, shown on its controller until block L2 brings real hands and gestures.
## A label over the hand ("Left: plastic jerrycan - gasoline 1.3 / 10.0 L") and, for a container, a level gauge
## beside it that rises while a fill runs (highlighted then). Data: CddaSim.get_held via HandsPanel's helpers,
## which clamp the numbers and cap the names.
## Live item tiles (lead-vr): with the held item's tile (ItemTile, VrRig gives it on each snapshot) the gauge is
## in its contents' colour and also shows a container get_held gives no numbers for (the tile's fill), its back
## takes the temperature's colour (frost, cold, heat), a strip beside it the spoilage colour, and the tile's words
## ("Cold", "Spoilage 95% (old)", "Fouling 40%") stand under the name in the temperature's colour.

const GAUGE_W := 0.014
const GAUGE_H := 0.09
const LABEL_PX := 0.00035   # metres per label pixel: about 1 cm letters at arm's length
const BACK := Color(0.1, 0.1, 0.12, 0.45)
const TEMP_BACK := 0.6      # how much of the temperature's colour the gauge's back takes at full strength
const ROT_W := 0.004        # the spoilage strip

var side: String           # "Left" / "Right"
var ratio := -1.0          # shown fill level, 0..1; -1 = no gauge
var tile := {}             # the held item's tile (ItemTile), {} for none
var _label: Label3D
var _state: Label3D        # the tile in words, under the name
var _gauge: Node3D
var _fill: MeshInstance3D
var _fill_mat: StandardMaterial3D
var _back_mat: StandardMaterial3D
var _rot: MeshInstance3D
var _rot_mat: StandardMaterial3D


func _init(side_name: String) -> void:
	side = side_name
	name = side_name + "Held"
	position = Vector3(0, 0.05, 0.06)   # over the placeholder hand (vr_rig.gd)
	visible = false
	_label = Label3D.new()
	_label.pixel_size = LABEL_PX
	_label.font_size = 32
	_label.outline_size = 8
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = false
	_label.position = Vector3(0, 0.03, 0)
	add_child(_label)
	_state = Label3D.new()
	_state.pixel_size = LABEL_PX
	_state.font_size = 24
	_state.outline_size = 8
	_state.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_state.no_depth_test = true
	_state.fixed_size = false
	_state.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_state.position = Vector3(0, 0.023, 0)
	_state.visible = false
	add_child(_state)
	var x := 0.045 if side_name == "Right" else -0.045
	_gauge = Node3D.new()
	_gauge.position = Vector3(x, -0.01, 0)
	add_child(_gauge)
	var back := MeshInstance3D.new()
	var back_box := BoxMesh.new()
	back_box.size = Vector3(GAUGE_W, GAUGE_H, GAUGE_W)
	_back_mat = StandardMaterial3D.new()
	_back_mat.albedo_color = BACK
	_back_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_back_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	back_box.material = _back_mat
	back.mesh = back_box
	_gauge.add_child(back)
	_fill = MeshInstance3D.new()
	var fill_box := BoxMesh.new()
	fill_box.size = Vector3(GAUGE_W * 0.8, GAUGE_H, GAUGE_W * 0.8)
	_fill_mat = StandardMaterial3D.new()
	_fill_mat.albedo_color = HandsPanel.LEVEL_COLOR
	_fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_box.material = _fill_mat
	_fill.mesh = fill_box
	_gauge.add_child(_fill)
	_rot = MeshInstance3D.new()   # inside the gauge, toward the hand
	var rot_box := BoxMesh.new()
	rot_box.size = Vector3(ROT_W, GAUGE_H, ROT_W)
	_rot_mat = StandardMaterial3D.new()
	_rot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rot_box.material = _rot_mat
	_rot.mesh = rot_box
	_rot.position = Vector3(x - signf(x) * (GAUGE_W * 0.5 + ROT_W), -0.01, 0)
	_rot.visible = false
	add_child(_rot)


## `hand` is one hand of a get_held() result ({} when empty); `filling` while ACT_FILL_LIQUID runs; `t` the held
## item's tile (ItemTile.for_item; {} for none).
func show_hand(hand: Dictionary, filling: bool, t: Dictionary = {}) -> void:
	visible = not hand.is_empty()
	tile = t if visible else {}
	var level := float(tile.get("level", -1.0)) if tile.get("level") is float else -1.0
	ratio = HandsPanel.fill_ratio(hand)
	var numbers := ratio >= 0.0   # get_held says how full: the name line has the litres
	if not numbers and level >= 0.0:
		ratio = clampf(level, 0.0, 1.0)
	_label.text = HandsPanel.hand_text(side, hand)
	_gauge.visible = visible and ratio >= 0.0
	_fill.visible = ratio > 0.0
	if ratio > 0.0:
		_fill.scale = Vector3(1, ratio, 1)
		_fill.position = Vector3(0, -GAUGE_H * 0.5 + GAUGE_H * ratio * 0.5, 0)
	var liquid: Variant = tile.get("liquid")
	var level_color: Color = liquid if liquid is Color and level > 0.0 else HandsPanel.LEVEL_COLOR
	_fill_mat.albedo_color = HandsPanel.FILL_COLOR if filling else level_color
	var tc: Variant = tile.get("temp_color")
	var temp: Color = tc if tc is Color else Color(0, 0, 0, 0)
	_back_mat.albedo_color = Color(BACK.lerp(Color(temp, 1.0), clampf(temp.a, 0.0, 1.0) * TEMP_BACK), BACK.a)
	var rc: Variant = tile.get("rot_color")
	_rot.visible = visible and rc is Color and (rc as Color).a > 0.0 and int(tile.get("rot", -1)) >= 0
	if _rot.visible:
		_rot_mat.albedo_color = rc
	_state.text = VrTile.words(tile, not numbers)
	_state.visible = visible and not _state.text.is_empty()
	_state.modulate = VrTile.color(tile)
	_label.modulate = HandsPanel.FILL_COLOR if filling else Color.WHITE
