class_name ExplosionView
extends Node3D
## Explosions from the bridge's `explosion` events (contracts/events.md): `pos` centre, `amount` radius in
## squares, `text` CDDA's kind (blast, fire_blast, flashbang, shockwave), `detail` the itype of what exploded
## (grenade, C4, rocket ammo, ...; 0 unknown), `path` the blast area. Each gets an effect from `profile_for`:
## a fireball growing to the radius, a light, smoke, glowing squares over the area, a ring for shockwaves,
## and for a flashbang a white screen flash that fades (stronger the closer the camera). Effects only: what
## the blast did comes from the snapshot. Anything malformed is skipped; at most MAX_LIVE at once.

const MAX_LIVE := 16
const MAX_AREA := 1024
const MAX_RADIUS := 60
const SQUARE_M := 1.0

## kind -> look. fire / smoke / light colours, seconds, size factor of the radius.
const KINDS := {
	"blast": {"fire": Color(1.0, 0.55, 0.15), "smoke": Color(0.25, 0.24, 0.22), "light": Color(1.0, 0.6, 0.25),
			"time": 0.9, "size": 1.0, "ring": false, "flash": 0.0},
	"fire_blast": {"fire": Color(1.0, 0.4, 0.05), "smoke": Color(0.2, 0.17, 0.15), "light": Color(1.0, 0.45, 0.1),
			"time": 1.4, "size": 1.2, "ring": false, "flash": 0.0},
	"flashbang": {"fire": Color(1.0, 1.0, 0.95), "smoke": Color(0.75, 0.75, 0.75), "light": Color(1.0, 1.0, 1.0),
			"time": 0.5, "size": 0.35, "ring": false, "flash": 1.0},
	"shockwave": {"fire": Color(0.8, 0.85, 1.0, 0.5), "smoke": Color(0.5, 0.5, 0.5), "light": Color(0.7, 0.8, 1.0),
			"time": 0.7, "size": 1.0, "ring": true, "flash": 0.0},
}
## Item id parts that change the look (first match wins).
const ITEM_LOOKS := [
	["flashbang", {"flash": 1.0}],
	["c4", {"size": 1.3, "time": 1.3, "smoke_scale": 1.6}],
	["dynamite", {"size": 1.2, "time": 1.2, "smoke_scale": 1.5}],
	["tnt", {"size": 1.2, "time": 1.2, "smoke_scale": 1.5}],
	["rocket", {"size": 1.1, "fire": Color(1.0, 0.7, 0.3)}],
	["rpg", {"size": 1.1, "fire": Color(1.0, 0.7, 0.3)}],
	["m72", {"size": 1.1, "fire": Color(1.0, 0.7, 0.3)}],
	["law", {"size": 1.1, "fire": Color(1.0, 0.7, 0.3)}],
	["40x", {"size": 0.9}],
	["grenade", {"size": 1.0}],
	["molotov", {"fire": Color(1.0, 0.35, 0.05), "time": 1.6}],
	["pipebomb", {"smoke_scale": 1.3}],
]

var world: WorldView
var flash_rect: ColorRect          # full-screen white for flashbangs (main.gd puts it on the HUD)
var _live: Array[Dictionary] = []   # {root, fire, smoke, ring, light, t, p}
var _flash := 0.0
var _shake := 0.0                  # 0..1, fades; camera offset in metres = SHAKE_M * _shake
var _shake_t := 0.0
var _sounds := {}                  # kind -> AudioStreamWAV (made once)

const SHAKE_M := 0.12
const SHAKE_FADE := 1.6            # per second
const SOUND_RATE := 22050


func _init(w: WorldView) -> void:
	name = "Explosions"
	world = w
	flash_rect = ColorRect.new()
	flash_rect.name = "Flash"
	flash_rect.color = Color(1, 1, 1, 0)
	flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE


## The look of one explosion: KINDS[kind] (blast for unknown kinds) changed by the item's id.
static func profile_for(kind: String, item_id: String) -> Dictionary:
	var p: Dictionary = (KINDS.get(kind, KINDS["blast"]) as Dictionary).duplicate()
	p["kind"] = kind if KINDS.has(kind) else "blast"
	p["smoke_scale"] = 1.0
	var id := item_id.to_lower()
	for l: Array in ITEM_LOOKS:
		if id.contains(l[0]):
			p.merge(l[1], true)
			break
	return p


func on_events(events: Array) -> void:
	for e: Variant in events:
		if e is Dictionary and e.get("kind") == "explosion":
			start(e)


## One explosion event; false if malformed or too many are showing.
func start(e: Dictionary) -> bool:
	if world == null or _live.size() >= MAX_LIVE or not e.get("pos") is Vector3i:
		return false
	var radius := clampi(int(e.get("amount", 0)) if e.get("amount") is int else 0, 0, MAX_RADIUS)
	var kind: String = e.get("text") if e.get("text") is String else "blast"
	var item_id := ""
	if e.get("detail") is int and int(e["detail"]) > 0 and world.tables != null:
		var d: IdTables.Def = world.tables.def_at("itype", int(e["detail"]))
		item_id = d.id if d != null else ""
	var p := profile_for(kind.left(32), item_id)
	var r_m := maxf(radius, 1) * SQUARE_M * float(p["size"])
	var root := Node3D.new()
	root.position = world.coords.ms_center_to_world(e["pos"]) + Vector3(0, 0.6, 0)
	add_child(root)
	var fire := _sphere(p["fire"], 1.0)
	root.add_child(fire)
	var smoke := _sphere(p["smoke"], 0.6)
	smoke.visible = false
	root.add_child(smoke)
	var ring: MeshInstance3D = null
	if p["ring"]:
		ring = _ring(p["fire"])
		root.add_child(ring)
	var light := OmniLight3D.new()
	light.light_color = p["light"]
	light.omni_range = r_m * 3.0 + 4.0
	light.light_energy = 6.0
	root.add_child(light)
	var area: Array = e.get("path") if e.get("path") is Array else []
	if not area.is_empty():
		root.add_child(_area_glow(area.slice(0, MAX_AREA), root.position, p["fire"]))
	_live.append({"root": root, "fire": fire, "smoke": smoke, "ring": ring, "light": light, "t": 0.0, "p": p,
			"r": r_m})
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var dist := cam.global_position.distance_to(root.global_position) if cam != null else 0.0
	if float(p["flash"]) > 0.0:
		_flash = maxf(_flash, float(p["flash"]) * clampf(1.0 - dist / 20.0, 0.0, 1.0))
	# Shake: stronger for bigger blasts, fading out over ~6 radii; flashbangs and shockwaves shake too.
	_shake = maxf(_shake, clampf(1.0 - dist / (r_m * 6.0 + 4.0), 0.0, 1.0) * clampf(r_m / 4.0, 0.3, 1.0))
	var snd := AudioStreamPlayer3D.new()
	snd.stream = sound_for(p["kind"], r_m)
	snd.unit_size = 6.0 + r_m * 2.0
	snd.max_distance = 200.0
	root.add_child(snd)
	if is_inside_tree():
		snd.play()
	return true


func live_count() -> int:
	return _live.size()


func flash_strength() -> float:
	return _flash


func _process(delta: float) -> void:
	tick(delta)


## Advances every effect by `delta` seconds (tests call it directly).
func tick(delta: float) -> void:
	_flash = maxf(_flash - delta * 0.8, 0.0)
	_shake = maxf(_shake - delta * SHAKE_FADE, 0.0)
	_shake_t += delta
	flash_rect.color.a = _flash
	for i in range(_live.size() - 1, -1, -1):
		var x: Dictionary = _live[i]
		x["t"] += delta
		var p: Dictionary = x["p"]
		var dur: float = p["time"]
		var k := clampf(x["t"] / dur, 0.0, 1.0)
		var r: float = x["r"]
		var fire: MeshInstance3D = x["fire"]
		fire.scale = Vector3.ONE * maxf(r * ease(minf(k * 2.5, 1.0), 0.4), 0.05)
		(fire.material_override as StandardMaterial3D).albedo_color.a = 1.0 - k
		var smoke: MeshInstance3D = x["smoke"]
		smoke.visible = k > 0.15
		smoke.scale = Vector3.ONE * r * float(p["smoke_scale"]) * (0.4 + k)
		smoke.position.y = k * r * 0.8
		(smoke.material_override as StandardMaterial3D).albedo_color.a = 0.6 * (1.0 - k)
		if x["ring"] != null:
			(x["ring"] as MeshInstance3D).scale = Vector3.ONE * maxf(r * k, 0.05)
		(x["light"] as OmniLight3D).light_energy = 6.0 * (1.0 - minf(k * 2.0, 1.0))
		if x["t"] >= dur:
			(x["root"] as Node3D).queue_free()
			_live.remove_at(i)


func shake_strength() -> float:
	return _shake


## Camera offset for the current shake (main.gd puts it in Camera3D.h_offset / v_offset).
func shake_offset() -> Vector2:
	if _shake <= 0.0:
		return Vector2.ZERO
	return Vector2(sin(_shake_t * 61.0) + 0.5 * sin(_shake_t * 23.0),
			cos(_shake_t * 53.0) + 0.5 * sin(_shake_t * 31.0)) * SHAKE_M * _shake * _shake


## A boom made once per kind and size class: noise through a falling low-pass, with a decaying envelope.
## Flashbangs are a sharp bright crack, shockwaves a low thump, blasts a crack and a rumble.
func sound_for(kind: String, r_m: float) -> AudioStreamWAV:
	var big := r_m >= 4.0
	var key := "%s:%s" % [kind, big]
	if _sounds.has(key):
		return _sounds[key]
	var secs: float = {"flashbang": 0.5, "shockwave": 1.0}.get(kind, 1.6 if big else 1.1)
	var n := int(SOUND_RATE * secs)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	var lp := 0.0
	for i in n:
		var t := float(i) / SOUND_RATE
		var env := exp(-t * (14.0 if kind == "flashbang" else (3.0 if big else 4.5)))
		var cut := (0.9 if kind == "flashbang" else 0.35) * exp(-t * 6.0) + (0.02 if kind != "flashbang" else 0.1)
		if kind == "shockwave":
			cut *= 0.4
		lp += (rng.randf_range(-1.0, 1.0) - lp) * cut
		var v := clampf(lp * env * (2.5 if kind != "flashbang" else 1.2), -1.0, 1.0)
		data.encode_s16(i * 2, int(v * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SOUND_RATE
	w.data = data
	_sounds[key] = w
	return w


func shift(d: Vector3) -> void:
	for x in _live:
		(x["root"] as Node3D).position += d


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = c
	return m


static func _sphere(c: Color, a: float) -> MeshInstance3D:
	var s := SphereMesh.new()
	s.radius = 1.0
	s.height = 2.0
	s.radial_segments = 16
	s.rings = 8
	var mi := MeshInstance3D.new()
	mi.mesh = s
	mi.material_override = _mat(Color(c, a))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.scale = Vector3.ONE * 0.05
	return mi


static func _ring(c: Color) -> MeshInstance3D:
	var t := TorusMesh.new()
	t.inner_radius = 0.92
	t.outer_radius = 1.0
	var mi := MeshInstance3D.new()
	mi.mesh = t
	mi.material_override = _mat(Color(c, 0.7))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Glowing floor squares over the blast area (one MultiMesh), relative to the explosion's root.
func _area_glow(area: Array, centre: Vector3, c: Color) -> MultiMeshInstance3D:
	var q := PlaneMesh.new()
	q.size = Vector2(SQUARE_M * 0.95, SQUARE_M * 0.95)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = q
	var pts: Array[Vector3] = []
	for sq: Variant in area:
		if sq is Vector3i:
			pts.append(world.coords.ms_center_to_world(sq) + Vector3(0, 0.04, 0) - centre)
	mm.instance_count = pts.size()
	for i in pts.size():
		mm.set_instance_transform(i, Transform3D(Basis(), pts[i]))
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = _mat(Color(c, 0.35))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
