extends Node3D
## M1 "ghost walk" viewer: loads a snapshot (default: the mock town), meshes it, and shows it in first person
## (block C9, FirstPersonCamera: WASD walks with VrWalk's collisions, [ ] level down / up) or from outside
## (the fly camera); V switches. Keys: PageUp/PageDown show levels up to z (cutaway), R roofs, F5 reload the
## snapshot, Home back to the player. Command line, after `--`: --view=first|outside --snapshot=<path>
## --ids=<id tables path> --view-z=<z> --no-roofs --camera=<x>,<y>,<z>,<yaw_deg>,<pitch_deg> (Godot metres,
## fly camera; starts outside unless --view says otherwise) --screenshot=<png> (save one frame, quit).
## --live plays a new CDDA game through the bridge instead (--cdda=<absolute dir> overrides ../cdda): the
## first-person camera stands on the player's square; arrows / numpad (and WASD in first person) move
## relative to where you look, KP5 or . waits, [ ] take stairs. CDDA's prompts show in RequestUI
## (scripts/ui/, block E3): mouse or keys, each widget lists its keys.
## --vr shows it in a PC VR headset (block L1, scripts/vr/); Godot itself must run with --xr-mode on (before
## `--`). Options --vr-move= --vr-turn= --vr-snap= --vr-speed= --vr-vignette= (VrRig.settings_from_args).

const HELP := "RMB look  WASD move  E/Q up/down  Shift fast  wheel speed  PgUp/PgDn level  R roofs  F5 reload  Home player  V first person"
const FP_HELP := "RMB look  WASD walk  Shift fast  [ ] level down/up  PgUp/PgDn cutaway  R roofs  F5 reload  Home player  V outside view"
const LIVE_HELP := "RMB look  WASD fly  arrows/numpad walk  KP5/. wait  [ ] stairs  prompts: mouse or keys, Esc cancels  PgUp/PgDn level  R roofs  Home player  V first person"
const LIVE_FP_HELP := "RMB look  WASD/arrows/numpad walk where you look  KP5/. wait  [ ] stairs  prompts: mouse or keys, Esc cancels  PgUp/PgDn cutaway  R roofs  V outside view"
## Live first person: a held move key queues the next step once the sim took the last one, at most this often.
const STEP_REPEAT_MS := 250
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
var camera: FlyCamera          # the outside view
var fp: FirstPersonCamera      # the first-person view (C9)
var first_person := true
var sun: DirectionalLight3D
var hud: Label
var request_ui: RequestUI
var player_marker: MeshInstance3D
var live: LiveSession
var vr: VrRig
var vr_perf: VrPerf
var _quitting := false
var snapshot_path := ""
var status := ""
var _args := {}
var _log := PackedStringArray()
var _step_ms := -STEP_REPEAT_MS


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
	InputActions.ensure()
	camera = FlyCamera.new()
	add_child(camera)
	fp = FirstPersonCamera.new(world)
	add_child(fp)
	world.coords.origin_shifted.connect(func(d: Vector3) -> void: camera.position += d)
	world.coords.origin_shifted.connect(fp.shift)
	_setup_hud()
	_setup_player_marker()
	var view := FirstPersonCamera.view_from_args(_args)
	if _args.has("view") and _args["view"] != view:
		push_warning("--view= takes first or outside; starting in %s" % view)
	_set_first_person(view == "first")
	if _args.has("live"):
		_start_live()
	else:
		_load_id_tables()
		_reload()
	if _args.has("view-z"):
		world.set_view_z_max(String(_args["view-z"]).to_int())
	if _args.has("no-roofs"):
		world.set_roofs_visible(false)
	if _args.has("vr"):
		_start_vr()
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
	player_marker.visible = not _fp_active()   # in first person the marker is you
	player_marker.position = world.coords.ms_center_to_world(snap.player_pos) + Vector3(0, 0.85, 0)
	if vr != null:
		world.set_view_z_max(CddaCoords.Z_MAX)   # first person: every level, ceilings included


func _frame_player() -> void:
	if world.snapshot == null:
		return
	if vr != null:
		vr.go_to_player(world.snapshot.player_pos)
		print("VR: player square %s, rig at %s, head at %s, player at %s" % [world.snapshot.player_pos,
				vr.global_position, vr.camera.global_position,
				world.coords.ms_center_to_world(world.snapshot.player_pos)])
		return
	if first_person:
		if live != null:
			fp.follow_square(world.snapshot.player_pos)
		else:
			fp.go_to_square(world.snapshot.player_pos)
		return
	_frame_outside(world.coords.ms_center_to_world(world.snapshot.player_pos))


func _frame_outside(target: Vector3) -> void:
	camera.look_from(target + Vector3(-20, 28, 30), target)


func _fp_active() -> bool:
	return vr == null and first_person


## C9: first person (true) or the outside fly camera. VR has its own rig and ignores this.
func _set_first_person(on: bool) -> void:
	if on and not first_person:
		fp.set_look(camera.rotation.y, 0.0)   # keep facing the same way
		world.set_view_z_max(CddaCoords.Z_MAX)   # ceilings back
	first_person = on
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	camera.set_process_unhandled_input(not on)
	fp.set_process_unhandled_input(on)
	(fp if on else camera).make_current()
	player_marker.visible = world.snapshot != null and not on


func _toggle_view() -> void:
	if vr != null:
		return
	_set_first_person(not first_person)
	if not first_person:
		_frame_outside(fp.position - Vector3(0, FirstPersonCamera.EYE_H, 0))


## The headset view (block L1). OpenXR only starts when Godot runs with --xr-mode on.
func _start_vr() -> void:
	var xr := XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized():
		status = "VR: OpenXR isn't running. Start Godot with --xr-mode on, with the headset's runtime (SteamVR, Meta) on"
		push_error(status)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)   # the headset paces the frames
	get_viewport().use_xr = true
	vr = VrRig.new(world, VrRig.settings_from_args(_args))
	add_child(vr)
	vr.camera.make_current()
	camera.set_process_unhandled_input(false)
	fp.set_process_unhandled_input(false)
	player_marker.visible = world.snapshot != null
	world.coords.origin_shifted.connect(func(d: Vector3) -> void: vr.position += d)
	get_tree().auto_accept_quit = false   # closing the window goes through _quit
	if xr.has_signal("session_stopping"):
		xr.connect("session_stopping", _quit)
	for sig in ["session_begun", "session_visible", "session_focussed", "session_stopping", "session_loss_pending"]:
		if xr.has_signal(sig):
			xr.connect(sig, func() -> void: print("VR: " + sig))
	if xr.has_signal("pose_recentered"):
		xr.connect("pose_recentered", func() -> void: XRServer.center_on_hmd(XRServer.RESET_BUT_KEEP_TILT, true))
	vr_perf = VrPerf.new(xr)
	add_child(vr_perf)
	if world.snapshot != null:
		world.set_view_z_max(CddaCoords.Z_MAX)
	print("VR on: %s" % vr.settings)


func _view() -> Node3D:
	if vr != null:
		return vr.camera
	return fp if first_person else camera


func _start_live() -> void:
	live = LiveSession.new()
	live.name = "Live"
	add_child(live)
	live.id_tables_ready.connect(world.set_id_tables)
	live.snapshot_ready.connect(_on_live_snapshot)
	live.request_changed.connect(_on_live_request)
	live.events_arrived.connect(_on_live_events)
	live.state_changed.connect(func(s: String) -> void:
		status = "game " + s + ("" if live.error.is_empty() else ": " + live.error)
		print("live: " + status))   # in the console too: in VR the HUD isn't in the headset
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
	fp.follow_square(snap.player_pos)   # also while outside, so V comes back to the player
	status = "turn %d: %s" % [snap.turn, status]
	if first:
		print("live: " + status)
		_frame_player()


func _on_live_request(req: Dictionary) -> void:
	if req.is_empty() or req.get("timed", false):
		request_ui.clear()   # the main loop: walking keys queue actions
		return
	print("live: request %s %s %s" % [req.get("kind", "?"), req.get("context", ""),
			str(req.get("text", "")).left(120).replace("\n", " ")])
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
	return octant_for(_view().global_basis, dir)


## Octant (index into OCT_ACTIONS) of a (right, forward) direction for a view with basis b.
static func octant_for(b: Basis, dir: Vector2) -> int:
	var fwd := -b.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = b.y   # looking straight down: up on screen is forward
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
	var in_main_loop := _in_main_loop()
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


func _in_main_loop() -> bool:
	return live.request.is_empty() or live.request.get("timed", false)


## Live first person: WASD / left stick walk where you look. A press queues a step at once (`now`); held, the
## next step waits until the sim has taken the last one, so letting go leaves nothing queued.
func _fp_live_step(now: bool) -> void:
	var mv := Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward")
	if mv == Vector2.ZERO or not _in_main_loop():
		return
	var t := Time.get_ticks_msec()
	if not now and (t - _step_ms < STEP_REPEAT_MS or live.queued_actions() > 0):
		return
	live.queue_action(OCT_ACTIONS[_octant(mv)])
	_step_ms = t


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
	var typing := request_ui.wants_text_input()   # typing must not move the camera
	camera.set_process(vr == null and not first_person and not typing)
	fp.set_process(_fp_active() and not typing)
	if _fp_active() and live != null and not typing:
		_fp_live_step(false)
	var tile := world.coords.world_to_ms(_view().global_position)
	var view := "first person" if _fp_active() else "outside, speed %.0f" % camera.speed
	var help := (LIVE_FP_HELP if _fp_active() else LIVE_HELP) if live != null else (FP_HELP if _fp_active() else HELP)
	var lines := PackedStringArray([status, "%s  camera square %s  view z <= %d  roofs %s  %d fps" % [
			view, tile, world.view_z_max, "on" if world.roofs_visible else "off",
			Engine.get_frames_per_second()], help])
	if vr != null:
		lines.append("VR level %d  %s" % [vr.z, vr_perf.last_line])
	lines.append_array(_log)
	hud.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"view_toggle"):
		_toggle_view()
		return
	if _fp_active() and live != null:
		for a: StringName in [&"move_forward", &"move_back", &"move_left", &"move_right"]:
			if event.is_action_pressed(a):
				_fp_live_step(true)
				return
	elif _fp_active() and world.snapshot != null:
		for dz: int in [1, -1]:
			if event.is_action_pressed(&"level_up" if dz > 0 else &"level_down"):
				var ok := fp.change_level(dz)
				status = ("level %d" % fp.z) if ok else ("nowhere to stand on level %d" % (fp.z + dz))
				return
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
	while live != null and world.snapshot == null and live.state != "failed" and live.state != "ended":
		await get_tree().process_frame   # a live game: wait for its first world
	for i in 4:
		await get_tree().process_frame
	var img: Image
	if vr != null:
		# The XR view can't be read back: a plain camera at the head's pose renders the same scene.
		var sv := SubViewport.new()
		sv.size = Vector2i(1280, 720)
		sv.render_target_update_mode = SubViewport.UPDATE_ONCE
		var cam := Camera3D.new()
		cam.fov = 90.0
		sv.add_child(cam)
		add_child(sv)
		cam.global_transform = vr.camera.global_transform
		cam.current = true
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		img = sv.get_texture().get_image()
	else:
		await RenderingServer.frame_post_draw
		img = get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("screenshot %s: %s" % [path, error_string(err)])
	_quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and vr != null:
		_quit()


## VR quits through here. Once a session has drawn frames, the engine's teardown crashes inside SteamVR on
## Windows (access violation; Vulkan, D3D12 and OpenGL alike, even with XR turned off first; 2026-11-06,
## SteamVR 2.18.4, null driver). So: turn XR off, free the scene (the live game's thread joins, files close),
## and with SteamVR on Windows end the process before that teardown (exit code 0).
func _quit() -> void:
	if _quitting:
		return
	_quitting = true
	if vr != null:
		var xr := XRServer.find_interface("OpenXR")
		var runtime := ""
		if xr != null:
			runtime = str(xr.get_system_info().get("XRRuntimeName", ""))
		vr_perf.set_process(false)
		get_viewport().use_xr = false
		if xr != null and xr.is_initialized():
			xr.uninitialize()
		await get_tree().process_frame
		for c in get_children():
			c.free()
		print("VR off (%s)" % runtime)
		if OS.get_name() == "Windows" and runtime.contains("SteamVR"):
			OS.kill(OS.get_process_id())
	get_tree().quit()
