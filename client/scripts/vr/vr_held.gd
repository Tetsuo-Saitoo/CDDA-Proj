class_name VrHeld
extends Node3D
## Live game in VR: what one hand holds, shown on its controller until block L2 brings real hands and gestures.
## A label over the hand ("Left: plastic jerrycan - gasoline 1.3 / 10.0 L") and, for a container, a level gauge
## beside it that rises while a fill runs (highlighted then). Data: CddaSim.get_held via HandsPanel's helpers,
## which clamp the numbers and cap the names.

const GAUGE_W := 0.014
const GAUGE_H := 0.09
const LABEL_PX := 0.00035   # metres per label pixel: about 1 cm letters at arm's length

var side: String           # "Left" / "Right"
var ratio := -1.0          # shown fill level, 0..1; -1 = no gauge
var _label: Label3D
var _gauge: Node3D
var _fill: MeshInstance3D
var _fill_mat: StandardMaterial3D


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
	_gauge = Node3D.new()
	_gauge.position = Vector3(0.045 if side_name == "Right" else -0.045, -0.01, 0)
	add_child(_gauge)
	var back := MeshInstance3D.new()
	var back_box := BoxMesh.new()
	back_box.size = Vector3(GAUGE_W, GAUGE_H, GAUGE_W)
	var back_mat := StandardMaterial3D.new()
	back_mat.albedo_color = Color(0.1, 0.1, 0.12, 0.45)
	back_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	back_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	back_box.material = back_mat
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


## `hand` is one hand of a get_held() result ({} when empty); `filling` while ACT_FILL_LIQUID runs.
func show_hand(hand: Dictionary, filling: bool) -> void:
	visible = not hand.is_empty()
	ratio = HandsPanel.fill_ratio(hand)
	_label.text = HandsPanel.hand_text(side, hand)
	_gauge.visible = visible and ratio >= 0.0
	_fill.visible = ratio > 0.0
	if ratio > 0.0:
		_fill.scale = Vector3(1, ratio, 1)
		_fill.position = Vector3(0, -GAUGE_H * 0.5 + GAUGE_H * ratio * 0.5, 0)
	_fill_mat.albedo_color = HandsPanel.FILL_COLOR if filling else HandsPanel.LEVEL_COLOR
	_label.modulate = HandsPanel.FILL_COLOR if filling else Color.WHITE
