class_name VrLook
extends Node3D
## Look at, in VR (VrRig `looking`): while the left X button is held (no menu, panel or wheel up), a ring on the
## square the player looks at (VrRig.look: the eyes when tracked, else the head) and a line over it naming what is
## there (LookRay) and how far. Looking only shows: while the ring is up, the main trigger asks for the cheat
## teleport to its square (`teleport_to`, as J with a flat look open). Nothing is done by gaze alone.

const LOOK_S := 0.05            # the ray looks again at most this often
const RING_Y := 0.03            # the ring this far over the ground
const LABEL_Y := 0.5            # the line this far over the ring
const COLOR := Color(1.0, 0.8, 0.3)

var held := false               # the button is down (VrRig.press / release)
var marked: Variant = null      # the ring's square (Vector3i), null when none
var text := ""                  # the line shown (tests)
## main.gd: (Vector3i) -> int, the cheat teleport there: the op id, 0 when not allowed or not sent.
var teleport_to := Callable()

var _ring: MeshInstance3D
var _label: Label3D
var _wait := 0.0


func _init() -> void:
	name = "Look"
	top_level = true   # placed in world space
	var torus := TorusMesh.new()
	torus.inner_radius = 0.3
	torus.outer_radius = 0.4
	torus.rings = 24
	torus.ring_segments = 6
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = COLOR
	torus.material = m
	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring.scale = Vector3(1, 0.15, 1)
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.pixel_size = 0.0008
	_label.font_size = 28
	_label.outline_size = 8
	_label.no_depth_test = true
	_label.modulate = COLOR
	_label.position = Vector3(0, LABEL_Y, 0)
	add_child(_label)
	visible = false


## Per frame (VrRig): `look` is VrRig.look(), `can` false while a menu, panel or wheel is up, `cheats`: the teleport
## is allowed. Shows the ring and line while held, else hides them.
func update(delta: float, world: WorldView, look: Dictionary, can: bool, cheats: bool) -> void:
	if not held or not can or look.is_empty() or world == null or world.snapshot == null:
		hide_look()
		return
	_wait -= delta
	if visible and _wait > 0.0:
		return
	_wait = LOOK_S
	var r := LookRay.new(world).cast(look["from"], look["dir"])
	r["dir"] = look["dir"]
	show_hit(world, r, look["from"], cheats and teleport_to.is_valid())


## Places the ring and line for LookRay hit `r` seen from `from`; `teleport`: the line says the trigger teleports.
func show_hit(world: WorldView, r: Dictionary, from: Vector3, teleport: bool) -> void:
	visible = true
	marked = null
	if not r.get("hit", false) or not r.get("square") is Vector3i or not r.get("point") is Vector3:
		text = "nothing there"
		_ring.visible = false
		_label.text = text
		var dir := (r.get("dir", Vector3.ZERO) as Vector3) if r.get("dir") is Vector3 else Vector3.ZERO
		global_position = from + dir * 2.0 - Vector3(0, LABEL_Y, 0)
		return
	var sq: Vector3i = r["square"]
	var me := world.snapshot.player_pos
	var d := sq - me
	text = "%s, %d squares (%.1f m)" % [str(r.get("what", "")).left(60), maxi(absi(d.x), absi(d.y)),
			from.distance_to(r["point"])]
	if d.z != 0:
		text += ", %d level%s %s" % [absi(d.z), "" if absi(d.z) == 1 else "s", "up" if d.z > 0 else "down"]
	marked = TeleportAim.square(r, r.get("dir", Vector3.ZERO), world.coords.world_to_ms)
	var at := world.coords.ms_center_to_world(marked if marked is Vector3i else sq)
	at.y = world.ground_y(at, (marked if marked is Vector3i else sq).z) + RING_Y
	global_position = at
	_ring.visible = marked is Vector3i
	if teleport and marked is Vector3i:
		text += "\ntrigger: teleport here"
	_label.text = text


func hide_look() -> void:
	visible = false
	marked = null
	text = ""
	_wait = 0.0


## The main trigger while the ring is up: the cheat teleport to its square. False (the rig buzzes) when there is no
## square, cheats are off or it wasn't sent.
func teleport(cheats: bool) -> bool:
	if not visible or not marked is Vector3i or not cheats or not teleport_to.is_valid():
		return false
	var id: Variant = teleport_to.call(marked)
	return id is int and id > 0
