extends Node3D
## M1 "ghost walk" viewer: loads a snapshot (default: the mock town), meshes it, and lets you fly around.
## Keys: PageUp/PageDown show levels up to z (cutaway), R roofs, F5 reload the snapshot, Home back to
## the player. Command line, after `--`: --snapshot=<path> --view-z=<z> --no-roofs
## --camera=<x>,<y>,<z>,<yaw_deg>,<pitch_deg> (Godot metres) --screenshot=<png> (save one frame, quit).
## --live plays a new CDDA game through the bridge instead (--cdda=<absolute dir> overrides ../cdda):
## arrows / numpad move relative to the camera, KP5 or . waits, [ ] take stairs. CDDA's prompts show in
## RequestUI (scripts/ui/, block E3): mouse or keys, each widget lists its keys.

const HELP := "RMB look  WASD move  E/Q up/down  Shift fast  wheel speed  PgUp/PgDn level  R roofs  F5 reload  Home player"
const LIVE_HELP := "RMB look  WASD fly  arrows/numpad walk  KP5/. wait  [ ] stairs  prompts: mouse or keys, Esc cancels  PgUp/PgDn level  R roofs  Home player"
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
var request_ui: RequestUI
var player_marker: MeshInstance3D
var live: LiveSession
var snapshot_path := ""
var status := ""
var _args := {}
var _log := PackedStringArray()


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
	status = "rebuilt %d of %d submaps in %d ms, %d k vertices" % [n, snap.submaps.size(),
			Time.get_ticks_msec() - t0, world.vertex_count / 1000]
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
	live.snapshot_ready.connect(_on_live_snapshot)
	live.request_changed.connect(_on_live_request)
	live.events_arrived.connect(_on_live_events)
	live.state_changed.connect(func(s: String) -> void:
		status = "game " + s + ("" if live.error.is_empty() else ": " + live.error))
	var user_dir := OS.get_user_data_dir().path_join("cdda")
	if live.start(_args.get("cdda", _repo_path("cdda")), user_dir, LIVE_WORLD):
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
	if req.is_empty() or req.get("timed", false):
		request_ui.clear()   # the main loop: walking keys queue actions
		return
	if req.get("context", "") == "RAW_KEY":
		# A raw key read: CDDA's debug message prompt and "press any key" screens (the text is only in
		# debug.log). Space goes on.
		request_ui.clear()
		live.answer({"id": req["id"], "action": " "})
		return
	if not request_ui.show_request(req):
		push_warning("live: request without a usable id or kind: %s" % req)


func _on_request_answered(a: Dictionary) -> void:
	if live != null and not live.answer(a):
		push_warning("live: bridge refused the answer %s" % a)


func _on_live_events(events: Array) -> void:
	for e: Dictionary in events:
		if e.get("kind", "") == "message":
			_log.append(CddaText.plain(str(e.get("text", ""))).left(200))
	if _log.size() > LOG_LINES:
		_log = _log.slice(_log.size() - LOG_LINES)


func _octant(dir: Vector2) -> int:
	var fwd := -camera.global_basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = camera.global_basis.y   # looking straight down: up on screen is forward
		fwd.y = 0.0
	fwd = fwd.normalized()
	var v := Vector3(-fwd.z, 0.0, fwd.x) * dir.x + fwd * dir.y
	return wrapi(roundi(atan2(v.z, v.x) / (PI / 4.0)), 0, 8)


## Camera-relative CDDA step for a (right, forward) screen direction; RequestUI uses it for directions and
## the target cursor.
func _screen_step(dir: Vector2) -> Vector2i:
	return OCT_STEPS[_octant(dir)]


## Live-mode keys in the main loop (prompts take their keys in RequestUI first); true if used.
func _live_key(code: Key) -> bool:
	var req := live.request
	var in_main_loop: bool = req.is_empty() or req.get("timed", false)
	if MOVE_KEYS.has(code):
		if in_main_loop:
			live.queue_action(OCT_ACTIONS[_octant(MOVE_KEYS[code])])
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
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(hud)
	request_ui = RequestUI.new()
	request_ui.direction_mapper = _screen_step
	request_ui.answered.connect(_on_request_answered)
	layer.add_child(request_ui)


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
	camera.set_process(not request_ui.wants_text_input())   # typing must not fly the camera
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
