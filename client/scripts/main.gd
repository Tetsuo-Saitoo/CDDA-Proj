extends Node3D
## M1 "ghost walk" viewer: loads a snapshot (default: the mock town), meshes it, and shows it in first person
## (block C9, FirstPersonCamera: WASD walks with VrWalk's collisions, [ ] level down / up) or from outside
## (the fly camera); V switches. Keys: PageUp/PageDown show levels up to z (cutaway), R roofs, F5 reload the
## snapshot, Home back to the player; every one is an action in InputActions and F1 opens the key menu
## (KeyMenu) to rebind them. Command line, after `--`: --view=first|outside --snapshot=<path>
## --ids=<id tables path> --view-z=<z> --no-roofs --camera=<x>,<y>,<z>,<yaw_deg>,<pitch_deg> (Godot metres,
## fly camera; starts outside unless --view says otherwise) --screenshot=<png> (save one frame, quit)
## --keys (start with the key menu open) --creatures=snap (creatures jump from square to square instead of
## walking) --demo-creatures (mock town: monsters and an NPC near the player that walk and attack).
## --live plays CDDA through the bridge instead (--cdda=<absolute dir> overrides ../cdda), starting at CDDA's main
## menu (MainMenu: new game with character creation, or load); --quick skips it (a random character in a
## fresh world fp3d-live), --world=/--save= load directly. In the game the
## first-person camera stands on the player's square; arrows / numpad (and WASD in first person) move
## relative to where you look, KP5 or . waits, [ ] take stairs. CDDA's prompts show in RequestUI
## (scripts/ui/, block E3): mouse or keys, each widget lists its keys.
## --vr shows it in a PC VR headset (block L1, scripts/vr/); Godot itself must run with --xr-mode on (before
## `--`). Settings: the in-headset menu (left menu button) saves them to user://vr.json; options --vr-move=
## --vr-turn= --vr-snap= --vr-speed= --vr-vignette= --vr-layout= --vr-hands= ... win over it (VrSettings.ARGS).

## Live first person: a held move key queues the next step once the sim took the last one, at most this often.
const STEP_REPEAT_MS := 250
const LIVE_WORLD := "fp3d-live"
const LOG_LINES := 6
## Camera-relative move: octant 0 = east, counting clockwise as seen from above (CDDA's y points south).
const OCT_ACTIONS := ["RIGHT", "RIGHTDOWN", "DOWN", "LEFTDOWN", "LEFT", "LEFTUP", "UP", "RIGHTUP"]
const OCT_STEPS := [Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0),
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]

var world: WorldView
var camera: FlyCamera          # the outside view
var fp: FirstPersonCamera      # the first-person view (C9)
var first_person := true
var sun: DirectionalLight3D
var hud: Label
var request_ui: RequestUI
var main_menu: MainMenu
var key_menu: KeyMenu
var compass: Compass
var hud_settings := HudSettings.new()   # compass opacity (F1 menu, user://hud.cfg)
var look_panel: Label
var hands_panel: HandsPanel
var look_ray: LookRay
var _look_line: MeshInstance3D   # player -> what was clicked
var gore: GoreView               # blood, gibs and bile fields on the ground
var explosions: ExplosionView    # blasts, flashbangs, shockwaves from explosion events
var aim: AimController           # FPS aiming for target requests: crosshair, 3D picking, cursor marker
var grab: GrabController         # doors dragged with the mouse (E6), hover outline, hand pointer
var viewmodel: WeaponViewmodel    # the wielded weapon, low right of the first-person view
var creature_view: CreatureView   # placeholder figures for NPCs and monsters (C4)
var player_body: PlayerBody       # the player's own body and clothes (all views; head hidden in first person/VR)
var _demo_step := 0
var live: LiveSession
var vr: VrRig
var vr_perf: VrPerf
var _quitting := false
var _saving_to_quit := false
var _save_asked := false   # the player's save (F5, closing the window), not an autosave
const SAVE_ON_QUIT_MS := 20000
var snapshot_path := ""
var status := ""
var _args := {}
var _log := PackedStringArray()
var _step_ms := -STEP_REPEAT_MS
var _submit_ms := 0
var _first_live_snapshot := true


func _ready() -> void:
	_args = _parse_args()
	snapshot_path = _args.get("snapshot", _repo_path("contracts/mock/snapshot_town.json"))
	world = WorldView.new()
	world.name = "World"
	world.catalog.load_registry_dir(_repo_path("assets/registry"))
	for w in world.catalog.warnings:
		push_warning(w)
	add_child(world)
	creature_view = CreatureView.new()
	creature_view.name = "Creatures"
	creature_view.smooth = str(_args.get("creatures", "smooth")) != "snap"
	add_child(creature_view)
	player_body = PlayerBody.new()
	player_body.name = "PlayerBody"
	add_child(player_body)
	_setup_environment()
	for problem in InputActions.ensure():
		push_warning("keys: " + problem)
	camera = FlyCamera.new()
	add_child(camera)
	fp = FirstPersonCamera.new(world)
	add_child(fp)
	world.coords.origin_shifted.connect(func(d: Vector3) -> void: camera.position += d)
	world.coords.origin_shifted.connect(fp.shift)
	world.coords.origin_shifted.connect(creature_view.shift)
	_setup_hud()
	gore = GoreView.new()
	add_child(gore)
	world.coords.origin_shifted.connect(gore.shift)
	explosions = ExplosionView.new(world)
	add_child(explosions)
	world.coords.origin_shifted.connect(explosions.shift)
	request_ui.get_parent().add_child(explosions.flash_rect)
	aim = AimController.new(world, request_ui)
	aim.creature_view = creature_view
	aim.wielded_gun = func() -> IdTables.Def:
		var i := world.snapshot.player_wielded if world.snapshot != null else 0
		var d: IdTables.Def = world.tables.def_at("itype", i) if world.tables != null and i > 0 else null
		return d if d != null and d.gun != "" else null
	add_child(aim)
	request_ui.get_parent().add_child(aim.crosshair)
	request_ui.get_parent().move_child(aim.crosshair, request_ui.get_index())
	grab = GrabController.new(world)
	add_child(grab)
	request_ui.get_parent().add_child(grab.icon)
	request_ui.get_parent().move_child(grab.icon, request_ui.get_index())
	grab.reach = _reach_square
	world.door_wants.connect(_on_door_wants)
	world.door_message.connect(func(t: String) -> void: _log.append(t))
	viewmodel = WeaponViewmodel.new()
	fp.add_child(viewmodel)
	aim.fired.connect(viewmodel.kick)
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
	if _args.has("keys"):
		_open_key_menu()
	if _args.has("screenshot"):
		_screenshot_and_quit(_args["screenshot"])


## A file of the repo (cdda/, assets/, contracts/). An exported game (the AppImage) has them next to its executable.
func _repo_path(rel: String) -> String:
	var root := ProjectSettings.globalize_path("res://").path_join("..")
	if OS.has_feature("template"):
		root = OS.get_executable_path().get_base_dir()
	return root.path_join(rel).simplify_path()


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
	if _args.has("demo-creatures"):
		_add_demo_creatures(snap)
	_show(snap)
	status = "turn %d seq %d: load %d ms, %s" % [snap.turn, snap.seq, t1 - t0, status]
	print(status)


## Shows a validated snapshot; `status` gets the rebuild stats.
func _show(snap: Snapshot) -> void:
	var t0 := Time.get_ticks_msec()
	_shown(snap, world.apply_snapshot(snap), t0)


## The rest of showing a snapshot once the world has it (apply_snapshot, or WorldView.applied in live mode).
func _shown(snap: Snapshot, n: int, t0: int) -> void:
	creature_view.show_player = false   # PlayerBody draws the player
	creature_view.apply(snap, world)
	gore.view_z_max = world.view_z_max
	gore.apply(snap, world)
	player_body.apply(snap, world.tables)
	status = "rebuilt %d of %d submaps in %d ms, %d k vertices, %d furniture, %d items" % [n,
			snap.submaps.size(), Time.get_ticks_msec() - t0, world.vertex_count / 1000,
			world.prop_counts["furniture"], world.prop_counts["items"]]
	_aim_sun(snap.sun_alt_deg, snap.sun_az_deg)
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


## First person and VR: the body stands under the eyes and turns with them, head hidden. Outside: on the
## player's square, facing the way first person last looked.
func _place_player_body() -> void:
	if world.snapshot == null:
		player_body.visible = false
		return
	var own := vr != null or first_person
	player_body.show_head = not own
	var at := world.coords.ms_center_to_world(world.snapshot.player_pos)
	var yaw := fp.yaw
	if vr != null:
		at = Vector3(vr.camera.global_position.x, vr.floor_y(), vr.camera.global_position.z)
		yaw = vr.camera.global_rotation.y
	elif first_person:
		at = fp.position - Vector3(0, FirstPersonCamera.EYE_H, 0)
	player_body.position = at
	if vr != null:
		player_body.follow_head(yaw, get_process_delta_time())
		# the rig poses the hands and the arms after this (VrRig.drive_body)
	else:
		player_body.rotation = Vector3(0, yaw, 0)
	player_body.visible = own or world.snapshot.player_pos.z <= world.view_z_max


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
	vr = VrRig.new(world, VrSettings.from_args(_args, VrSettings.load_file()))
	vr.save_path = VrSettings.FILE
	vr.body = player_body   # one hand system: the body's arms reach for the VR hands
	vr.compass.opacity = hud_settings.compass_opacity
	add_child(vr)
	vr.grab_ok = func(sq: Vector3i) -> bool:   # live: CDDA opens doors next to the player only
		var p: Variant = _reach_square()
		return live == null or (p != null and sq.z == p.z and absi(sq.x - p.x) <= 1 and absi(sq.y - p.y) <= 1)
	vr.camera.make_current()
	camera.set_process_unhandled_input(false)
	fp.set_process_unhandled_input(false)
	world.coords.origin_shifted.connect(func(d: Vector3) -> void: vr.position += d)
	get_tree().auto_accept_quit = false   # closing the window goes through _quit
	if xr.has_signal("session_stopping"):
		xr.connect("session_stopping", _save_and_quit)
	for sig in ["session_begun", "session_visible", "session_focussed", "session_stopping", "session_loss_pending"]:
		if xr.has_signal(sig):
			xr.connect(sig, func() -> void: print("VR: " + sig))
	if xr.has_signal("pose_recentered"):
		xr.connect("pose_recentered", func() -> void: XRServer.center_on_hmd(XRServer.RESET_BUT_KEEP_TILT, true))
	vr_perf = VrPerf.new(xr)
	add_child(vr_perf)
	vr.live_stairs = live != null
	vr.stair_used.connect(func(st: Dictionary) -> void: use_stair(st, true))
	if live != null:
		live.held_changed.connect(vr.show_held)   # the hands panel isn't in the headset
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
	world.door_local = false   # doors open when CDDA opens them
	add_child(live)
	live.id_tables_ready.connect(world.set_id_tables)
	live.snapshot_ready.connect(_on_live_snapshot)
	world.applied.connect(_on_world_applied)
	live.request_changed.connect(_on_live_request)
	live.events_arrived.connect(_on_live_events)
	live.state_changed.connect(func(s: String) -> void:
		status = "game " + s + ("" if live.error.is_empty() else ": " + live.error)
		print("live: " + status))   # in the console too: in VR the HUD isn't in the headset
	live.saved.connect(_on_live_saved)
	live.held_changed.connect(hands_panel.show_held)
	get_tree().auto_accept_quit = false   # closing the window saves first (_save_and_quit)
	# --live alone: continues the game in LIVE_WORLD (its first save), or starts one there if it has none.
	# --live --new: a new game in LIVE_WORLD, replacing it and its saves. --world=<name> and/or --save=<character>
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
	elif _args.has("quick"):
		ok = live.start(data_dir, user_dir, LIVE_WORLD)
	else:
		_show_main_menu(data_dir, user_dir)
		return
	_after_live_start(ok)


## --live without --world/--save/--quick: CDDA's main menu (MainMenu), then a new game (character creation
## through a `chargen` request, ChargenRequestWidget) or a load.
func _show_main_menu(data_dir: String, user_dir: String) -> void:
	main_menu = MainMenu.new()
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.add_child(main_menu)
	request_ui.get_parent().add_child(center)
	main_menu.setup(LiveSession.list_worlds(user_dir),
			func(w: String) -> PackedStringArray: return LiveSession.list_saves(user_dir, w))
	main_menu.new_game.connect(func(w: String, fresh: bool, chargen: bool, setup: bool) -> void:
		_menu_started(center, live.start_new_game(data_dir, user_dir, w, fresh, chargen, setup)))
	main_menu.load_game.connect(func(w: String, sv: String) -> void:
		_menu_started(center, live.start_load(data_dir, user_dir, w, sv)))
	main_menu.quit_requested.connect(_quit)
	status = "main menu"


func _menu_started(center: Control, ok: bool) -> void:
	if not ok:
		main_menu.set_message(live.error)
		return
	center.queue_free()
	main_menu = null
	_after_live_start(true)


func _after_live_start(ok: bool) -> void:
	if ok:
		status = "game booting (~30 s)"
	else:
		status = "live mode failed: " + live.error
		push_error(status)


## F5: saves and plays on. Autosaves (LiveSession) only show in the message log.
func _save_game() -> void:
	if live.save():
		_save_asked = true
		status = "saving..."
	else:
		status = "can't save now (no running game)"


func _on_live_saved(ok: bool) -> void:
	if _save_asked:
		_save_asked = false
		status = "game saved" if ok else "saving failed (see the message log)"
		print("live: " + status)


## Closing the window during a live game saves it first, then quits. A prompt still open is cancelled so the sim
## gets back to the main loop; a long activity (sleep, reading) can hold the save up, so it gives up after
## SAVE_ON_QUIT_MS and quits anyway (autosave keeps at most a few minutes of play from being lost).
func _save_and_quit() -> void:
	if _quitting or _saving_to_quit:
		return
	if live == null or not live.save():
		_quit()
		return
	_saving_to_quit = true
	_save_asked = true
	status = "saving before quitting..."
	print("live: " + status)
	var deadline := Time.get_ticks_msec() + SAVE_ON_QUIT_MS
	while live.save_pending() and live.state == "running" and Time.get_ticks_msec() < deadline:
		var r := live.request
		if not r.is_empty() and not r.get("timed", false):
			live.answer({"id": r["id"], "cancel": true})
		await get_tree().process_frame
	if live.save_pending():
		push_warning("live: quitting without saving (the game didn't get back to its main loop)")
	_quit()


## Live: meshing runs on a worker (WorldView.submit); _on_world_applied shows the rest when it is done.
func _on_live_snapshot(snap: Snapshot) -> void:
	_submit_ms = Time.get_ticks_msec()
	world.submit(snap)


func _on_world_applied(snap: Snapshot, n: int) -> void:
	var first := _first_live_snapshot
	_first_live_snapshot = false
	_shown(snap, n, _submit_ms)
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
	var door := GrabController.answer_for(grab.ask, req, Time.get_ticks_msec())
	if not door.is_empty():   # the "Open where?" of a door you dragged: its direction
		grab.ask = {}
		request_ui.clear()
		live.answer(door)
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
	creature_view.on_events(events)
	explosions.on_events(events)
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


## Live-mode actions in the main loop (prompts take their keys in RequestUI first); true if used.
func _live_action(event: InputEvent) -> bool:
	var act := ""
	for a: StringName in InputActions.STEPS:
		if InputActions.pressed(event, a):
			act = OCT_ACTIONS[_octant(InputActions.STEPS[a])]
	for a: StringName in InputActions.CDDA:
		if InputActions.pressed(event, a):
			act = InputActions.CDDA[a]
	if InputActions.pressed(event, &"wait"):
		act = "pause"
	elif InputActions.pressed(event, &"level_down"):
		act = "LEVEL_DOWN"
	elif InputActions.pressed(event, &"level_up"):
		act = "LEVEL_UP"
	elif InputActions.pressed(event, &"use_held"):
		# what the hands hold, used on the square you face (a hose + a container on a vehicle siphons)
		act = "fp3d_use_" + OCT_ACTIONS[_octant(Vector2(0, 1))]
	elif InputActions.pressed(event, &"hold_off"):
		act = "fp3d_hold_off"
	elif InputActions.pressed(event, &"stow_off"):
		act = "fp3d_stow_off"
	elif InputActions.pressed(event, &"hand_off") or InputActions.pressed(event, &"hand_main"):
		# strike the square you face: the left (off) hand or the right (main) hand
		var hand := "off" if InputActions.pressed(event, &"hand_off") else "main"
		act = "fp3d_attack_%s_%s" % [hand, OCT_ACTIONS[_octant(Vector2(0, 1))]]
	if act == "":
		return false
	if _in_main_loop():
		live.queue_action(act)
	return true


## Left click: what is under the mouse (the screen centre while the mouse looks around), with a line from
## the player to it, its distance and what the snapshot says is there.
func _look_at_screen(pos: Vector2) -> Dictionary:
	if world.snapshot == null:
		return {}
	if look_ray == null:
		look_ray = LookRay.new(world)
	var cam := get_viewport().get_camera_3d()
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		pos = get_viewport().get_visible_rect().size / 2.0
	var r := look_ray.cast(cam.project_ray_origin(pos), cam.project_ray_normal(pos))
	_clear_look()
	if not r["hit"]:
		look_panel.text = "look: nothing there"
		return r
	# From the chest: in first person a line from the eyes would run straight away from the view.
	var from := world.coords.ms_center_to_world(world.snapshot.player_pos) + Vector3(0, 1.0, 0)
	if _fp_active():
		from = fp.global_position - Vector3(0, 0.6, 0)
	var me := world.coords.world_to_ms(from)
	var sq: Vector3i = r["square"]
	var d := sq - me
	var where := "%d squares away (%.1f m)" % [maxi(absi(d.x), absi(d.y)), from.distance_to(r["point"])]
	if d.z != 0:
		where += ", %d level%s %s" % [absi(d.z), "" if absi(d.z) == 1 else "s", "up" if d.z > 0 else "down"]
	var lines := PackedStringArray(["look: %s, %s" % [r["what"], where]])
	lines.append_array(look_ray.describe(sq))
	look_panel.text = "
".join(lines)
	_look_line = _line_mesh(from, r["point"])
	add_child(_look_line)
	return r


## The level stairs are used from: the player's in a live game, else the viewer's.
func _stair_z() -> int:
	if live != null:
		return world.snapshot.player_pos.z
	return vr.z if vr != null else fp.z


## Takes stair s (StairUse.find; {} = not a stair, ignored). Live: CDDA's own actions (a step onto it when next to
## it, then < or >); mock: the first-person camera goes there (the VR rig moves itself). True when something
## happened.
func use_stair(s: Dictionary, from_vr := false) -> bool:
	if s.is_empty():
		return false
	if live != null:
		var acts := StairUse.live_actions(world.snapshot.player_pos, s)
		if acts.is_empty():
			status = "stairs: walk next to them first"
			return false
		if not _in_main_loop():
			return false
		for a in acts:
			live.queue_action(a)
		status = "stairs " + ("up" if s["dz"] > 0 else "down")
		return true
	if not from_vr and not fp.use_stair(s):
		status = "nowhere to stand on level %d" % (fp.z + s["dz"])
		return false
	status = "level %d" % (vr.z if from_vr else fp.z)
	return true


func _clear_look() -> void:
	if look_panel != null:
		look_panel.text = ""
	if _look_line != null:
		_look_line.queue_free()
		_look_line = null


## A line from a to b with a dot at b, drawn over everything.
static func _line_mesh(a: Vector3, b: Vector3) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.albedo_color = Color(1.0, 0.85, 0.2)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	im.surface_add_vertex(a)
	im.surface_add_vertex(b)
	im.surface_end()
	var dot := SphereMesh.new()
	dot.radius = 0.05
	dot.height = 0.1
	dot.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "LookLine"
	mi.mesh = im
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var d := MeshInstance3D.new()
	d.mesh = dot
	d.position = b
	d.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.add_child(d)
	return mi


## Name of what the player holds, from the newest snapshot and the id tables.
func _wielded_name() -> String:
	var idx := world.snapshot.player_wielded if world.snapshot != null else 0
	if idx <= 0:
		return "nothing"
	var d: IdTables.Def = world.tables.def_at("itype", idx) if world.tables != null else null
	return CddaText.plain(d.name).left(60) if d != null and d.name != "" else "item #%d" % idx


func _update_aim() -> void:
	aim.first_person = _fp_active()
	aim.update(get_viewport().get_camera_3d(), Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	var t := request_ui.target_widget()
	viewmodel.aimed = t != null and TargetRequestWidget.is_attack_mode(t.mode)
	viewmodel.visible = _fp_active()
	viewmodel.set_item(world.snapshot.player_wielded if world.snapshot != null else 0, world.tables)


func _in_main_loop() -> bool:
	return live.request.is_empty() or live.request.get("timed", false)


## The square hands and the mouse reach doors from: the player's; in mock first person, where you stand.
func _reach_square() -> Variant:
	if world.snapshot == null:
		return null
	if live == null and _fp_active():
		var sq := world.coords.world_to_ms(fp.position)
		return Vector3i(sq.x, sq.y, fp.z)
	return world.snapshot.player_pos


## A door leaf crossed its threshold (live): queue CDDA's open / close; its "where?" prompt is answered for it.
func _on_door_wants(square: Vector3i, open: bool) -> void:
	if live == null or world.snapshot == null or not _in_main_loop():
		return
	var act := grab.want(square, open, world.snapshot.player_pos, Time.get_ticks_msec())
	if act != "":
		live.queue_action(act)


## The mouse point grabbing and looking use: the screen centre while the mouse looks around.
func _pointer() -> Vector2:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return get_viewport().get_visible_rect().size / 2.0
	return get_viewport().get_mouse_position()


## Live first person: WASD / left stick walk where you look. A press queues a step at once (`now`); held, the
## next step waits until the sim has taken the last one, so letting go leaves nothing queued.
func _fp_live_step(now: bool) -> void:
	var mv := Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward")
	if mv == Vector2.ZERO or not _in_main_loop() or Input.is_key_pressed(KEY_SHIFT):
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
	hud.position = Vector2(10, 50)   # under the compass's hostile markers
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(hud)
	compass = Compass.new()
	compass.set_anchors_preset(Control.PRESET_CENTER_TOP)
	compass.offset_left = -180
	compass.offset_right = 180
	compass.offset_top = 6
	compass.offset_bottom = 32
	compass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(compass)
	var why := hud_settings.load_file()
	if why != "":
		push_warning("HUD settings: " + why)
	compass.opacity = hud_settings.compass_opacity
	look_panel = Label.new()
	look_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	look_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	look_panel.offset_left = 10
	look_panel.offset_top = -10
	look_panel.offset_bottom = -10
	look_panel.add_theme_color_override("font_outline_color", Color.BLACK)
	look_panel.add_theme_constant_override("outline_size", 4)
	look_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(look_panel)
	hands_panel = HandsPanel.new()
	layer.add_child(hands_panel)
	request_ui = RequestUI.new()
	request_ui.direction_mapper = _screen_step
	request_ui.answered.connect(_on_request_answered)
	request_ui.queue_after.connect(func(acts: PackedStringArray) -> void:
		for a in acts:
			if live != null:
				live.queue_action(a))
	layer.add_child(request_ui)
	key_menu = KeyMenu.new()
	key_menu.closed.connect(_on_key_menu_closed)
	key_menu.add_hud_settings(hud_settings)
	key_menu.hud_changed.connect(func() -> void: compass.opacity = hud_settings.compass_opacity)
	layer.add_child(key_menu)


func _open_key_menu() -> void:
	camera.set_process_unhandled_input(false)
	fp.set_process_unhandled_input(false)
	key_menu.open()


func _on_key_menu_closed() -> void:
	if vr == null:
		_set_first_person(first_person)   # cameras take their input again


## --demo-creatures (mock town): one of several body types each, and an NPC, near the player. Every second
## they step east or west; now and then they attack the player or flinch, as the bridge's events would say.
const DEMO_MONSTERS := ["mon_zombie", "mon_dog_zombie_cop", "mon_zombie_brute", "mon_ant",
		"mon_rattlesnake", "mon_crow", "mon_blob", "mon_bear", "mon_spider_wolf_giant", "mon_bee",
		"mon_zombie_child", "mon_skeleton_hulk"]


func _add_demo_creatures(snap: Snapshot) -> void:
	if world.tables == null:
		return
	var p := snap.player_pos
	var i := 0
	for id: String in DEMO_MONSTERS:
		var t := world.tables.index_of("mtype", id)
		if t < 0:
			continue
		var c := Snapshot.Creature.new()
		c.uid = (2 << 32) + i
		c.type = t
		c.pos = p + Vector3i(-7 + (i % 6) * 3, -4 - (i / 6) * 4, 0)
		snap.creatures.append(c)
		i += 1
	var npc := Snapshot.Creature.new()
	npc.uid = (1 << 32) + 1
	npc.kind = Snapshot.Creature.NPC
	npc.pos = p + Vector3i(3, 2, 0)
	snap.creatures.append(npc)
	snap.creatures_moved()
	if get_node_or_null("DemoTimer") == null:
		var timer := Timer.new()
		timer.name = "DemoTimer"
		timer.wait_time = 1.0
		timer.timeout.connect(_demo_tick)
		add_child(timer)
		timer.start()


func _demo_tick() -> void:
	var snap := world.snapshot
	if snap == null:
		return
	_demo_step += 1
	var dx := 1 if (_demo_step / 3) % 2 == 0 else -1
	var events := []
	for c in snap.creatures:
		if c.kind == Snapshot.Creature.PLAYER:
			continue
		c.pos.x += dx
		if _demo_step % 4 == 0:
			events.append({"kind": "attack", "uid": c.uid, "other": 1, "pos": snap.player_pos})
		elif _demo_step % 4 == 2:
			events.append({"kind": "damage", "uid": c.uid})
	snap.creatures_moved()
	creature_view.apply(snap, world)
	creature_view.on_events(events)


func _process(_delta: float) -> void:
	var typing := request_ui.wants_text_input() or key_menu.visible   # typing must not move the camera
	camera.set_process(vr == null and not first_person and not typing)
	fp.set_process(_fp_active() and not typing)
	if _fp_active() and live != null and not typing:
		_fp_live_step(false)
	compass.visible = vr == null
	_update_aim()
	var cam := get_viewport().get_camera_3d()
	if cam != null and vr == null:   # no shaking in VR (comfort)
		var o := explosions.shake_offset()
		cam.h_offset = o.x
		cam.v_offset = o.y
	grab.update(get_viewport().get_camera_3d(), _pointer(), _fp_active() and not typing
			and request_ui.target_widget() == null, Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	creature_view.view_z_max = world.view_z_max
	_place_player_body()
	compass.heading_deg = Compass.heading_of(_view().global_basis)
	if compass.visible:   # creatures the player perceives, by bearing from the view
		compass.set_blips(Compass.creature_blips(world.snapshot, _view().global_position,
				world.coords.ms_center_to_world))
	elif vr != null:   # the same blips on the VR wrist / belt compass (from the head)
		vr.compass.set_blips(Compass.creature_blips(world.snapshot, _view().global_position,
				world.coords.ms_center_to_world))
	var tile := world.coords.world_to_ms(_view().global_position)
	var view := "first person" if _fp_active() else "outside, speed %.0f" % camera.speed
	var help := _help()
	var lines := PackedStringArray([status, "%s  camera square %s  view z <= %d  roofs %s  %d fps" % [
			view, tile, world.view_z_max, "on" if world.roofs_visible else "off",
			Engine.get_frames_per_second()], help])
	if vr != null:
		lines.append("VR level %d  controllers %s  settings: left menu button  %s" % [vr.z, vr.current_layout(),
				vr_perf.last_line])
	if live != null:
		lines.append(_act_help())
		lines.append("in hands: " + _wielded_name())
	lines.append_array(_log)
	hud.text = "\n".join(lines)
	hud.visible = not key_menu.visible


## The view's key line, from the current bindings.
func _help() -> String:
	var k := InputActions.key_of
	var walk := _keys([&"move_forward", &"move_left", &"move_back", &"move_right"])
	var steps := _keys([&"step_forward", &"step_left", &"step_back", &"step_right"])
	var lv := "%s %s" % [k.call(&"level_down"), k.call(&"level_up")]
	var cut := "%s/%s" % [k.call(&"cutaway_up"), k.call(&"cutaway_down")]
	var out := "%s look  %s look at, hold on a door and drag to open  " % [k.call(&"look"), k.call(&"look_at")]
	if live != null and _fp_active():
		out += "%s or %s walk where you look  %s wait  %s stairs  prompts: mouse or keys, Esc cancels  %s cutaway  %s roofs  %s outside view" % [
				walk, steps, k.call(&"wait"), lv, cut, k.call(&"roofs_toggle"), k.call(&"view_toggle")]
	elif live != null:
		out += "%s fly  %s/%s up/down  %s walk  %s wait  %s stairs  prompts: mouse or keys, Esc cancels  %s level  %s roofs  %s player  %s first person" % [
				walk, k.call(&"fly_up"), k.call(&"fly_down"), steps, k.call(&"wait"), lv, cut,
				k.call(&"roofs_toggle"), k.call(&"frame_player"), k.call(&"view_toggle")]
	elif _fp_active():
		out += "%s walk  %s fast  %s level down/up  %s cutaway  %s roofs  %s reload  %s player  %s outside view" % [
				walk, k.call(&"move_fast"), lv, cut, k.call(&"roofs_toggle"), k.call(&"reload"),
				k.call(&"frame_player"), k.call(&"view_toggle")]
	else:
		out += "%s move  %s/%s up/down  %s fast  wheel speed  %s level  %s roofs  %s reload  %s player  %s first person" % [
				walk, k.call(&"fly_up"), k.call(&"fly_down"), k.call(&"move_fast"), cut, k.call(&"roofs_toggle"),
				k.call(&"reload"), k.call(&"frame_player"), k.call(&"view_toggle")]
	return out + "  F1 keys, HUD"


## Live game: the CDDA action keys and the hands, from the current bindings.
func _act_help() -> String:
	var parts := PackedStringArray()
	for a: StringName in InputActions.CDDA:
		parts.append("%s %s" % [InputActions.key_of(a), InputActions.info(a)[2]])
	parts.append("%s/%s hit left/right hand" % [InputActions.key_of(&"hand_off"), InputActions.key_of(&"hand_main")])
	parts.append("%s use / examine what you face  %s/%s hold / put away (left hand)" % [InputActions.key_of(&"use_held"),
			InputActions.key_of(&"hold_off"), InputActions.key_of(&"stow_off")])
	parts.append("%s save" % InputActions.key_of(&"save_game"))
	return "  ".join(parts)


## "WASD" when every key is one letter, else "W/A/S/D".
static func _keys(actions: Array) -> String:
	var ks := PackedStringArray()
	var short := true
	for a: StringName in actions:
		ks.append(InputActions.key_of(a))
		short = short and ks[-1].length() == 1
	return "".join(ks) if short else "/".join(ks)


func _unhandled_input(event: InputEvent) -> void:
	if key_menu.visible:
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.physical_keycode == InputActions.MENU_KEY:
		_open_key_menu()
		return
	if vr == null and aim.handle_event(event, get_viewport().get_camera_3d()):
		return
	if vr == null and grab.handle_event(event, get_viewport().get_camera_3d(), _pointer()):
		return
	if vr == null and InputActions.pressed(event, &"look_at"):
		var mb := event as InputEventMouseButton
		var hit := _look_at_screen(mb.position if mb != null else get_viewport().get_mouse_position())
		if _fp_active() and hit.get("hit", false):   # clicking stairs in first person takes them
			use_stair(StairUse.find(world, hit["square"], _stair_z()))
		return
	if InputActions.pressed(event, &"view_toggle"):
		_toggle_view()
		return
	if _fp_active() and live != null:
		for a: StringName in [&"move_forward", &"move_back", &"move_left", &"move_right"]:
			if InputActions.pressed(event, a):   # exactly: Shift+W is wear
				_fp_live_step(true)
				return
	elif _fp_active() and world.snapshot != null:
		for dz: int in [1, -1]:
			if InputActions.pressed(event, &"level_up" if dz > 0 else &"level_down"):
				var ok := fp.change_level(dz)
				status = ("level %d" % fp.z) if ok else ("nowhere to stand on level %d" % (fp.z + dz))
				return
	if live != null and InputActions.pressed(event, &"save_game"):
		_save_game()
		return
	if live != null and _live_action(event):
		return
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
		_clear_look()
	elif InputActions.pressed(event, &"cutaway_up"):
		world.set_view_z_max(world.view_z_max + 1)
	elif InputActions.pressed(event, &"cutaway_down"):
		world.set_view_z_max(world.view_z_max - 1)
	elif InputActions.pressed(event, &"roofs_toggle"):
		world.set_roofs_visible(not world.roofs_visible)
	elif InputActions.pressed(event, &"reload"):
		if live == null:
			_reload()
	elif InputActions.pressed(event, &"frame_player"):
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
	if what == NOTIFICATION_WM_CLOSE_REQUEST and (vr != null or live != null):
		_save_and_quit()


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
