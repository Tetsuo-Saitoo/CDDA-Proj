extends Node3D
## M1 "ghost walk" viewer: loads a snapshot (default: the mock town), meshes it, and lets you fly around.
## Keys: PageUp/PageDown show levels up to z (cutaway), R roofs, F5 reload the snapshot, Home back to
## the player. Command line, after `--`: --snapshot=<path> --ids=<id tables path> --view-z=<z> --no-roofs
## --camera=<x>,<y>,<z>,<yaw_deg>,<pitch_deg> (Godot metres) --screenshot=<png> (save one frame, quit).
## --live plays a new CDDA game through the bridge instead (--cdda=<absolute dir> overrides ../cdda):
## arrows / numpad move relative to the camera, KP5 or . waits, [ ] take stairs, 1-9 / Enter pick in a
## menu, Esc cancels it.

const HELP := "RMB look  WASD move  E/Q up/down  Shift fast  wheel speed  PgUp/PgDn level  R roofs  F5 reload  Home player"
const LIVE_HELP := "RMB look  WASD fly  arrows/numpad walk  KP5/. wait  [ ] stairs  1-9/Enter pick  Esc cancel  PgUp/PgDn level  R roofs  Home player"
const LIVE_WORLD := "fp3d-live"
const LOG_LINES := 6
## Camera-relative move: octant 0 = east, counting clockwise as seen from above (CDDA's y points south).
const OCT_ACTIONS := ["RIGHT", "RIGHTDOWN", "DOWN", "LEFTDOWN", "LEFT", "LEFTUP", "UP", "RIGHTUP"]
const OCT_STEPS := [Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0),
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]
## Key -> (right, forward) relative to the camera.
const MOVE_KEYS := {
	KEY_UP: Vector2(0, 1), KEY_DOWN: Vector2(0, -1), KEY_LEFT: Vector2(-1, 0), KEY_RIGHT: Vector2(1, 0),
	KEY_KP_8: Vector2(0, 1), KEY_KP_2: Vector2(0, -1), KEY_KP_4: Vector2(-1, 0), KEY_KP_6: Vector2(1, 0),
	KEY_KP_7: Vector2(-1, 1), KEY_KP_9: Vector2(1, 1), KEY_KP_1: Vector2(-1, -1), KEY_KP_3: Vector2(1, -1),
}

var world: WorldView
var camera: FlyCamera
var sun: DirectionalLight3D
var hud: Label
var request_label: Label
var player_marker: MeshInstance3D
var live: LiveSession
var snapshot_path := ""
var status := ""
var _args := {}
var _log := PackedStringArray()
var _options := []   # [label, answer] pairs for the pending request, picked with 1-9 / Enter
var _color_tags := RegEx.create_from_string("</?color[^>]*>")


func _ready() -> void:
	_args = _parse_args()
	snapshot_path = _args.get("snapshot", _repo_path("contracts/mock/snapshot_town.json"))
	world = WorldView.new()
	world.name = "World"
	world.catalog.load_registry_dir(_repo_path("assets/registry"))
	for w in world.catalog.warnings:
		push_warning(w)
	add_child(world)
	_setup_environment()
	camera = FlyCamera.new()
	add_child(camera)
	camera.make_current()
	world.coords.origin_shifted.connect(func(d: Vector3) -> void: camera.position += d)
	_setup_hud()
	_setup_player_marker()
	if _args.has("live"):
		_start_live()
	else:
		_load_id_tables()
		_reload()
	if _args.has("view-z"):
		world.set_view_z_max(String(_args["view-z"]).to_int())
	if _args.has("no-roofs"):
		world.set_roofs_visible(false)
	_frame_player()
	if _args.has("camera"):
		var c := String(_args["camera"]).split_floats(",")
		if c.size() == 5:
			camera.position = Vector3(c[0], c[1], c[2])
			camera.rotation = Vector3(deg_to_rad(c[4]), deg_to_rad(c[3]), 0)
	if _args.has("screenshot"):
		_screenshot_and_quit(_args["screenshot"])


func _repo_path(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()


func _parse_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			out[kv[0]] = kv[1] if kv.size() > 1 else ""
	return out


## Mock mode: the id tables next to the mock snapshot (live mode gets them from the game).
func _load_id_tables() -> void:
	var t := IdTables.load_file(_args.get("ids", _repo_path("contracts/mock/id_tables.json")))
	if not t.is_valid():
		push_warning("id tables rejected, showing registry art only: " + t.error)
	world.set_id_tables(t)


func _reload() -> void:
	var t0 := Time.get_ticks_msec()
	var snap := Snapshot.load_file(snapshot_path)
	if not snap.is_valid():
		status = "snapshot rejected: " + snap.error
		push_error(status)
		return
	var t1 := Time.get_ticks_msec()
	_show(snap)
	status = "turn %d seq %d: load %d ms, %s" % [snap.turn, snap.seq, t1 - t0, status]
	print(status)


## Shows a validated snapshot; `status` gets the rebuild stats.
func _show(snap: Snapshot) -> void:
	var t0 := Time.get_ticks_msec()
	var n := world.apply_snapshot(snap)
	status = "rebuilt %d of %d submaps in %d ms, %d k vertices, %d furniture, %d items" % [n,
			snap.submaps.size(), Time.get_ticks_msec() - t0, world.vertex_count / 1000,
			world.prop_counts["furniture"], world.prop_counts["items"]]
	_aim_sun(snap.sun_alt_deg, snap.sun_az_deg)
	player_marker.visible = true
	player_marker.position = world.coords.ms_center_to_world(snap.player_pos) + Vector3(0, 0.85, 0)


func _frame_player() -> void:
	if world.snapshot == null:
		return
	var target := world.coords.ms_center_to_world(world.snapshot.player_pos)
	camera.look_from(target + Vector3(-20, 28, 30), target)


func _start_live() -> void:
	live = LiveSession.new()
	live.name = "Live"
	add_child(live)
	live.id_tables_ready.connect(world.set_id_tables)
	live.snapshot_ready.connect(_on_live_snapshot)
	live.request_changed.connect(_on_live_request)
	live.events_arrived.connect(_on_live_events)
	live.state_changed.connect(func(s: String) -> void:
		status = "game " + s + ("" if live.error.is_empty() else ": " + live.error))
	# --live alone: a new game in LIVE_WORLD (replaced each time). --world=<name> and/or --save=<character>
	# load a saved game instead and never delete anything: --world alone takes its first save, --save alone
	# looks in LIVE_WORLD. Saves live under user://cdda/save/<world>/ (copy CDDA worlds there).
	var user_dir := OS.get_user_data_dir().path_join("cdda")
	var data_dir: String = _args.get("cdda", _repo_path("cdda"))
	var ok := false
	if _args.has("world") or _args.has("save"):
		var w: String = _args.get("world", LIVE_WORLD)
		var saves := LiveSession.list_saves(user_dir, w)
		var s: String = _args.get("save", saves[0] if not saves.is_empty() else "")
		if s.is_empty():
			live.error = "no saves in world %s (worlds: %s)" % [w, ", ".join(LiveSession.list_worlds(user_dir))]
		else:
			ok = live.start_load(data_dir, user_dir, w, s)
	else:
		ok = live.start(data_dir, user_dir, LIVE_WORLD)
	if ok:
		status = "game booting (~30 s)"
	else:
		status = "live mode failed: " + live.error
		push_error(status)


func _on_live_snapshot(snap: Snapshot) -> void:
	var first := world.snapshot == null
	_show(snap)
	status = "turn %d: %s" % [snap.turn, status]
	if first:
		print("live: " + status)
		_frame_player()


func _on_live_request(req: Dictionary) -> void:
	_options = []
	request_label.text = ""
	if req.is_empty() or req.get("timed", false):
		return
	if req.get("context", "") == "RAW_KEY":
		# A raw key read: CDDA's debug message prompt and "press any key" screens. Space goes on.
		live.answer({"id": req["id"], "action": " "})
		return
	_options = _request_options(req)
	var lines := PackedStringArray(["[%s] %s" % [req.get("kind", ""), _plain(req.get("title", ""))]])
	var text := _plain(req.get("text", ""))
	if not text.is_empty():
		lines.append(text.left(400))
	for i in _options.size():
		lines.append("%d  %s" % [i + 1, _plain(_options[i][0])])
	if req.get("kind", "") == "direction":
		lines.append("arrows / numpad: direction")
	lines.append("Esc  cancel")
	request_label.text = "\n".join(lines)


## [label, answer] pairs for the number keys: enabled entries of menus, else the request's actions.
func _request_options(req: Dictionary) -> Array:
	var out := []
	var kind: String = req.get("kind", "")
	if kind in ["menu", "item_select", "item_multi"]:
		for e: Dictionary in req.get("entries", []):
			if e.get("enabled", true):
				var a := {"id": req["id"]}
				if kind == "item_multi":
					a["picks"] = [[e["id"], 0]]
				else:
					a["entry"] = e["id"]
				out.append([e.get("label", ""), a])
	elif kind in ["key", "popup", "target"]:
		for act: String in req.get("actions", PackedStringArray()):
			var a := {"id": req["id"], "action": act}
			if kind == "target":
				a["pos"] = req.get("cursor", Vector3i.ZERO)
			out.append([act, a])
	return out.slice(0, 9)


func _on_live_events(events: Array) -> void:
	for e: Dictionary in events:
		if e.get("kind", "") == "message":
			_log.append(_plain(e.get("text", "")).left(200))
	if _log.size() > LOG_LINES:
		_log = _log.slice(_log.size() - LOG_LINES)


func _plain(s: String) -> String:
	return _color_tags.sub(s, "", true)


func _octant(dir: Vector2) -> int:
	var fwd := -camera.global_basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = camera.global_basis.y   # looking straight down: up on screen is forward
		fwd.y = 0.0
	fwd = fwd.normalized()
	var v := Vector3(-fwd.z, 0.0, fwd.x) * dir.x + fwd * dir.y
	return wrapi(roundi(atan2(v.z, v.x) / (PI / 4.0)), 0, 8)


## Live-mode keys; true if used.
func _live_key(code: Key) -> bool:
	var req := live.request
	var in_main_loop: bool = req.is_empty() or req.get("timed", false)
	if MOVE_KEYS.has(code):
		var oct := _octant(MOVE_KEYS[code])
		if req.get("kind", "") == "direction":
			var d: Vector2i = OCT_STEPS[oct]
			live.answer({"id": req["id"], "pos": Vector3i(d.x, d.y, 0)})
		elif in_main_loop:
			live.queue_action(OCT_ACTIONS[oct])
		return true
	match code:
		KEY_KP_5, KEY_PERIOD:
			if in_main_loop:
				live.queue_action("pause")
			return true
		KEY_BRACKETLEFT, KEY_BRACKETRIGHT:
			if in_main_loop:
				live.queue_action("LEVEL_DOWN" if code == KEY_BRACKETLEFT else "LEVEL_UP")
			return true
		KEY_ESCAPE:
			if not in_main_loop:
				live.answer({"id": req["id"], "cancel": true})
			return true
		KEY_ENTER, KEY_KP_ENTER:
			if not _options.is_empty():
				live.answer(_options[0][1])
			return true
	if code >= KEY_1 and code <= KEY_9:
		var i: int = code - KEY_1
		if i < _options.size():
			live.answer(_options[i][1])
		return true
	return false


func _setup_environment() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 200.0
	add_child(sun)
	_aim_sun(45.0, 0.0)


## CDDA's azimuth is measured from the south, positive toward the west (calendar.cpp).
func _aim_sun(alt_deg: float, az_deg: float) -> void:
	var alt := deg_to_rad(maxf(alt_deg, 8.0))
	var az := deg_to_rad(az_deg)
	var to_sun := Vector3(-sin(az) * cos(alt), sin(alt), cos(az) * cos(alt))
	sun.basis = Basis.looking_at(-to_sun, Vector3.FORWARD if absf(to_sun.y) > 0.99 else Vector3.UP)
	sun.light_energy = 1.0 if alt_deg > 0.0 else 0.15


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(10, 8)
	request_label = Label.new()
	request_label.position = Vector2(10, 260)
	for l: Label in [hud, request_label]:
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 4)
		layer.add_child(l)


## A stand-in for the player until there are character models.
func _setup_player_marker() -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.3
	mesh.height = 1.7
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.55, 0.1)
	mesh.material = mat
	player_marker = MeshInstance3D.new()
	player_marker.name = "PlayerMarker"
	player_marker.mesh = mesh
	player_marker.visible = false
	add_child(player_marker)


func _process(_delta: float) -> void:
	var tile := world.coords.world_to_ms(camera.position)
	var lines := PackedStringArray([status, "camera square %s  view z <= %d  roofs %s  speed %.0f  %d fps" % [
			tile, world.view_z_max, "on" if world.roofs_visible else "off", camera.speed,
			Engine.get_frames_per_second()], LIVE_HELP if live != null else HELP])
	lines.append_array(_log)
	hud.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if live != null and _live_key(k.physical_keycode):
		return
	match k.physical_keycode:
		KEY_PAGEUP:
			world.set_view_z_max(world.view_z_max + 1)
		KEY_PAGEDOWN:
			world.set_view_z_max(world.view_z_max - 1)
		KEY_R:
			world.set_roofs_visible(not world.roofs_visible)
		KEY_F5:
			if live == null:
				_reload()
		KEY_HOME:
			_frame_player()


func _screenshot_and_quit(path: String) -> void:
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("screenshot %s: %s" % [path, error_string(err)])
	get_tree().quit()
