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
## --no-light: no darkening by CDDA's light and night (WorldLighting, block C6).
## --live plays CDDA through the bridge instead (--cdda=<absolute dir> overrides ../cdda), starting at CDDA's main
## menu (MainMenu: new game with character creation, or load); --quick skips it (a random character in a
## fresh world fp3d-live, or fp3d-live-2 ... if a world it didn't make has that name), --world=/--save= load
## directly. In the game the
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
## CDDA's prompts on the VR panel are drawn this much larger (1 px is ~1.1 mm at 1.2 m; text wants 20 px or more).
const PANEL_UI_SCALE := 1.35
## Camera-relative move: octant 0 = east, counting clockwise as seen from above (CDDA's y points south).
const OCT_ACTIONS := ["RIGHT", "RIGHTDOWN", "DOWN", "LEFTDOWN", "LEFT", "LEFTUP", "UP", "RIGHTUP"]
const OCT_STEPS := [Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0),
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]

var world: WorldView
var camera: FlyCamera          # the outside view
var fp: FirstPersonCamera      # the first-person view (C9): the player's eyes in every view but outside
var first_person := true       # the eyes drive (first, shoulder, top); false = the outside fly camera
var view_cam: ViewCamera       # C9: shoulder and top views, following the eyes
var view_mode := "first"       # one of VIEW_MODES; saved in hud.cfg
const VIEW_MODES := HudSettings.VIEWS
var _top_z := 0                # top view: the level cut at (follows the player's level)
var sun: DirectionalLight3D
var weather: WeatherView       # C6 / I2: sky, sun and fog by CDDA's weather
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
var _look_end := Vector3.ZERO    # the looked-at point; the line's start follows the player (_update_look_line)
var gore: GoreView               # blood, gibs and bile fields on the ground
var fields_view: FieldView       # fire, sparks, smoke and gas fields
var explosions: ExplosionView    # blasts, flashbangs, shockwaves from explosion events
var aim: AimController           # FPS aiming for target requests: crosshair, 3D picking, cursor marker
var grab: GrabController         # doors dragged with the mouse (E6), hover outline, hand pointer
var item_actions: ItemActions     # one-item take / put / drop for mouse and VR hands (E6 / L2 / L8)
var hands: Hands                  # the hands (mouse, VR controllers): targets, holding, letting go
var world_collision: WorldCollision   # E2 item physics: floor / wall / furniture boxes near the player
var item_bodies: ItemBodies           # E2 item physics: the items near the player as physics bodies
var mock_items: MockItems         # mock mode: item actions done on the client's own snapshot
var inspect: InspectView          # Tab: hands, worn containers and the ground in reach; drag items between them
var hud_data := HudData.new()     # what the HUD shows (body, needs, held, messages, warnings), for screen and VR
var hud_view: HudView             # the screen view of hud_data
var pour := PourHold.new()        # E with a liquid in hand: a tap uses, a hold pours
var cheat_panel: CheatPanel       # the F1 menu's Cheats page (K7)
var _test_args_done := false      # --test / --cheats are applied once, when the game first runs
var viewmodel: WeaponViewmodel    # the wielded weapon, low right of the first-person view
var creature_view: CreatureView   # placeholder figures for NPCs and monsters (C4)
var player_body: PlayerBody       # the player's own body and clothes (all views; head hidden in first person/VR)
var _demo_step := 0
var live: LiveSession
## Where CDDA keeps its saves and config; empty: user://cdda. Live scripts set it before adding main, so they
## never touch the player's saves.
var cdda_user_dir := ""
var vr: VrRig
var vr_perf: VrPerf
var _quitting := false
var _saving_to_quit := false
var _save_asked := false   # the player's save (F5, closing the window), not an autosave
const SAVE_ON_QUIT_MS := 20000
var snapshot_path := ""
var status := ""
var _teleport_ops := {}   # op id -> true: teleports asked for, until range_done
var _args := {}
var _log := PackedStringArray()
var _step_ms := -STEP_REPEAT_MS
var _submit_ms := 0
var _first_live_snapshot := true
var _shot_refused := false   # a shot answer was refused (warned once)


## Boot timing in the log: milliseconds since the engine started, so slow starts can be read from any log.
static func _boot_log(what: String) -> void:
	print("boot: %6d ms  %s" % [Time.get_ticks_msec(), what])


func _on_first_frame_drawn() -> void:
	_boot_log("first frame drawn")


func _exit_tree() -> void:
	# Nothing of ours may stay connected to an engine singleton: a headless run never draws a frame, and the callable
	# still waiting on frame_post_draw crashed the engine as it shut down.
	if RenderingServer.frame_post_draw.is_connected(_on_first_frame_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_first_frame_drawn)


func _ready() -> void:
	_boot_log("main scene ready (engine, extensions, scene loaded)")
	_args = _parse_args()
	snapshot_path = _args.get("snapshot", _repo_path("contracts/mock/snapshot_town.json"))
	world = WorldView.new()
	world.name = "World"
	world.catalog.load_registry_dir(_repo_path("assets/registry"))
	world.lighting.enabled = not _args.has("no-light")
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
	view_cam = ViewCamera.new(fp)
	add_child(view_cam)
	view_cam.blocked = func(from: Vector3, to: Vector3) -> float:   # the shoulder boom stops at walls
		if look_ray == null:
			look_ray = LookRay.new(world)
		var d := to - from
		var r := look_ray.cast(from, d.normalized(), d.length(), false)
		return from.distance_to(r["point"]) if r.get("hit", false) and r.get("point") is Vector3 else INF
	world.coords.origin_shifted.connect(func(d: Vector3) -> void: camera.position += d)
	world.coords.origin_shifted.connect(fp.shift)
	world.coords.origin_shifted.connect(creature_view.shift)
	_setup_hud()
	gore = GoreView.new()
	add_child(gore)
	world.coords.origin_shifted.connect(gore.shift)
	fields_view = FieldView.new()
	add_child(fields_view)
	world.coords.origin_shifted.connect(fields_view.shift)
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
	grab.view = eyes_view   # over the shoulder / top-down: reach counts from the eyes, not the camera
	aim.view = eyes_view    # and aiming: picks from in front of the player, bullets from the eyes
	item_actions = ItemActions.new()
	add_child(item_actions)
	hands = Hands.new(world, item_actions)
	add_child(hands)
	grab.hands = hands
	# E2 item physics (slices 1-2, 5), desktop and VR alike, real time and turns: collision boxes and item bodies around
	# the square the hands reach from; the hands point at, grab and let go of the bodies (Hands.bodies). Client-side
	# poses only; nothing new is sent to CDDA. Bodies need WorldView's owner sets (set_hidden_items_for); without them
	# only the collision is built. Only with --item-physics until its main-thread cost in crowded places (stocked
	# stores) is shown to be low enough.
	if _args.has("item-physics"):
		world_collision = WorldCollision.new(world)
		world_collision.centre = _reach_square
		add_child(world_collision)
		item_bodies = ItemBodies.new(world, world_collision)
		item_bodies.centre = _reach_square
		item_bodies.held = item_actions.hidden   # items being taken stay static
		add_child(item_bodies)
		hands.bodies = item_bodies
	pour.actions = item_actions
	pour.held = _held_liquid
	pour.target = _pour_target
	pour.tap = _use_tap
	inspect = InspectView.new(hands, item_actions)
	request_ui.get_parent().add_child(inspect)
	request_ui.get_parent().move_child(inspect, request_ui.get_index())   # prompts and F1 draw over it
	inspect.opened.connect(func() -> void:   # the mouse is the view's while it is open
		camera.set_process_unhandled_input(false)
		fp.set_process_unhandled_input(false))
	inspect.closed.connect(func() -> void:
		camera.set_process_unhandled_input(vr == null and not first_person)
		fp.set_process_unhandled_input(vr == null and first_person))
	world.door_wants.connect(_on_door_wants)
	world.door_message.connect(func(t: String) -> void:
		_log.append(t)
		hud_data.on_events([MockItems.message_event(t)]))
	viewmodel = WeaponViewmodel.new()
	fp.add_child(viewmodel)
	aim.fired.connect(viewmodel.kick)
	_set_view(start_view(_args, hud_settings.view))
	_boot_log("client set up")
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
	_use_mock_items(snap)
	_show(snap)
	status = "turn %d seq %d: load %d ms, %s" % [snap.turn, snap.seq, t1 - t0, status]
	print(status)


## Mock mode: the hands take, put and drop items on the client's own copy of the snapshot (MockItems), so E6 can
## be tried without the bridge; every pile gets item handles first.
func _use_mock_items(snap: Snapshot) -> void:
	if inspect != null:
		inspect.stop_batch()   # its items were the old backend's
	item_actions.clear()
	mock_items = MockItems.new(snap, world.tables)
	mock_items.seed()
	item_actions.backend = mock_items
	mock_items.message.connect(func(t: String) -> void:
		_log.append(t)
		hud_data.on_events([MockItems.message_event(t)])
		item_actions.on_events([MockItems.message_event(t)]))
	mock_items.changed.connect(func(s: Snapshot) -> void:
		_show(s)
		item_actions.on_snapshot(s))


## Shows a validated snapshot; `status` gets the rebuild stats.
func _show(snap: Snapshot) -> void:
	var t0 := Time.get_ticks_msec()
	_shown(snap, world.apply_snapshot(snap), t0)


## The rest of showing a snapshot once the world has it (apply_snapshot, or WorldView.applied in live mode).
func _shown(snap: Snapshot, n: int, t0: int) -> void:
	creature_view.show_player = false   # PlayerBody draws the player
	creature_view.apply(snap, world)
	gore.view_z_max = world.things_z_max()
	gore.apply(snap, world)
	fields_view.view_z_max = world.things_z_max()
	fields_view.apply(snap, world)
	player_body.apply(snap, world.tables)
	inspect.refresh()
	hud_data.update(snap, world.tables)
	status = "rebuilt %d of %d submaps in %d ms, %d k vertices, %d furniture, %d items" % [n,
			snap.submaps.size(), Time.get_ticks_msec() - t0, world.vertex_count / 1000,
			world.prop_counts["furniture"], world.prop_counts["items"]]
	weather.apply(snap, world.coords, world.lighting.enabled)
	if vr != null:
		world.set_view_z_max(world.coords.z_max)   # first person: every level, ceilings included


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
	var own := vr != null or (first_person and view_mode == "first")
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
	player_body.visible = own or world.snapshot.player_pos.z <= world.things_z_max()


func _fp_active() -> bool:
	return vr == null and first_person


## C9: the eyes when the shown camera is away from them (shoulder, top), for aiming, grabbing and looking:
## {mode, eye (Vector3), facing (level, unit)}; {} in first person, outside and VR.
func eyes_view() -> Dictionary:
	if not _fp_active() or fp == null or not view_mode in ViewCamera.MODES:
		return {}
	return {"mode": view_mode, "eye": fp.global_position, "facing": ViewCamera.facing(fp.yaw)}


## C9: first person (true) or the outside fly camera. VR has its own rig and ignores this.
func _set_first_person(on: bool) -> void:
	if on and not first_person:
		fp.set_look(camera.rotation.y, 0.0)   # keep facing the same way
		world.set_view_z_max(world.coords.z_max)   # ceilings back
	first_person = on
	world.lighting.min_brightness = 0.0 if on else WorldLighting.OUTSIDE_MIN   # the map stays readable
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	camera.set_process_unhandled_input(not on)
	fp.set_process_unhandled_input(on)
	(fp if on else camera).make_current()


## The start view: --view=first|shoulder|top|outside, else --camera= (a fly pose) means outside, else the
## saved one.
static func start_view(args: Dictionary, saved: String) -> String:
	var v := String(args.get("view", ""))
	if v in VIEW_MODES:
		return v
	if args.has("view"):
		push_warning("--view= takes %s; starting in %s" % [", ".join(VIEW_MODES), saved])
	if args.has("camera"):
		return "outside"
	return saved if saved in VIEW_MODES else "first"


## C9: "first" (the eyes), "shoulder" / "top" (ViewCamera follows the eyes) or "outside" (the fly camera).
func _set_view(m: String) -> void:
	if not m in VIEW_MODES:
		m = "first"
	var was_top := view_mode == "top"
	view_mode = m
	_set_first_person(m != "outside")
	if m in ViewCamera.MODES:
		view_cam.mode = m
		view_cam.follow()
		view_cam.make_current()
	view_cam.set_process(m in ViewCamera.MODES)
	if m == "top":
		_top_z = fp.z
		world.set_view_z_max(fp.z)   # see the player from above: the levels over them cut away
	elif was_top and m != "outside":
		world.set_view_z_max(world.coords.z_max)
	world.lighting.min_brightness = WorldLighting.OUTSIDE_MIN if m in ["top", "outside"] else 0.0


## V: first person -> over the shoulder -> top-down -> outside (fly) -> first person; saved for next time.
func _toggle_view() -> void:
	if vr != null:
		return
	_set_view(VIEW_MODES[(VIEW_MODES.find(view_mode) + 1) % VIEW_MODES.size()])
	if view_mode == "outside":
		_frame_outside(fp.position - Vector3(0, FirstPersonCamera.EYE_H, 0))
	hud_settings.view = view_mode
	var err := hud_settings.save_file()
	if err != OK:
		push_warning("view not saved: %s" % error_string(err))


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
	vr.hud.data = hud_data   # body, needs, warnings, messages inside the off forearm
	vr.hands = hands   # the controllers are hands "vr_l" / "vr_r"; reach is the picker's (grab.reach)
	vr.cheats_backend = live   # K7: the VR menu's Cheats page (null in the mock; hidden until LiveSession has cheats())
	vr.cheats_allowed = key_menu != null and key_menu.cheats_allowed()   # kept in step each frame (_process)
	vr.cook.backend = live   # L9: recipe matches over pots on the heat (once LiveSession has match_recipes)
	vr.gun.aim = aim   # L2 guns by hand: fired from the muzzle (fire_from, live_aim), haptics on shots and kills
	vr.gun.actions = item_actions   # magazine out / in by hand (unload / reload)
	vr.gun.queue_action = func(a: String) -> bool: return live != null and _in_main_loop() and live.queue_action(a)
	add_child(vr)
	vr.camera.make_current()
	world.lighting.min_brightness = 0.0
	camera.set_process_unhandled_input(false)
	fp.set_process_unhandled_input(false)
	world.coords.origin_shifted.connect(vr.shift)   # the rig, its open pack and pulled copies' starts
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
	vr.stair_used.connect(func(st: Dictionary) -> void:
		status = "stairs: not now"   # use_stair says why when it knows
		if not use_stair(st, true):
			vr.refused_here(status))   # a buzz and the reason by the main hand (no status line in the headset)
	if live != null:
		live.held_changed.connect(vr.show_held)   # the hands panel isn't in the headset
	if world.snapshot != null:
		world.set_view_z_max(world.coords.z_max)
	# L4: CDDA's prompts on the VR panel (laser clicks, the stick's ui_* actions; RequestUI.as_key), and with them
	# the menus opened beside them later (the main menu: _show_main_menu adds it next to request_ui).
	var panel := panel_root(vr)
	if panel != null:
		request_ui.reparent(panel, false)
		request_ui.set_ui_scale(PANEL_UI_SCALE)   # 16 px text -> ~22 px: readable at the panel's distance
		request_ui.keyboard = true   # no keyboard in the headset: text prompts open with TextKeys
	print("VR on: %s" % vr.settings)


## The VR panel's root Control (VrPanel.root, a full-rect Control in its SubViewport), or null while `rig` has no
## panel (read by name: older rigs have none).
static func panel_root(rig: Object) -> Control:
	var p: Variant = rig.get("panel") if is_instance_valid(rig) else null
	var r: Variant = (p as Object).get("root") if p is Object and is_instance_valid(p) else null
	return r as Control if r is Control and is_instance_valid(r) else null


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
	live.busy = world.busy   # no new snapshot fetch while the last one is still being put on screen
	world.applied.connect(_on_world_applied)
	live.request_changed.connect(_on_live_request)
	live.events_arrived.connect(_on_live_events)
	live.state_changed.connect(func(s: String) -> void:
		status = "game " + s + ("" if live.error.is_empty() else ": " + live.error)
		print("live: " + status)   # in the console too: in VR the HUD isn't in the headset
		_boot_log("game " + s))
	live.saved.connect(_on_live_saved)
	live.held_changed.connect(hands_panel.show_held)
	live.held_changed.connect(hud_data.set_held)
	live.cheats_changed.connect(hud_data.set_cheats)
	live.cheats_changed.connect(cheat_panel.on_cheats_changed)
	live.state_changed.connect(_apply_test_args)
	live.state_changed.connect(inspect.on_game_state)   # a Tab batch stops when the game does
	cheat_panel.backend = live
	live.range_changed.connect(cheat_panel.on_range_changed)
	live.range_changed.connect(func(i: Dictionary) -> void: range_forces_cheats(i, key_menu, live))
	live.range_done.connect(cheat_panel.on_range_done)
	live.range_done.connect(func(id: int, err: String) -> void:
		if _teleport_ops.erase(id):
			status = "teleport: done" if err.is_empty() else "teleport: " + err)
	cheat_panel.teleport = func() -> int:   # the F1 entry: the square at the screen's centre
		return _teleport(get_viewport().get_visible_rect().size / 2.0)
	live.id_tables_ready.connect(func(t: IdTables) -> void: cheat_panel.tables = t)
	cheat_panel.player_square = func() -> Variant:
		return world.snapshot.player_pos if world.snapshot != null else null
	# monsters spawn two squares ahead of where the camera looks
	cheat_panel.ahead_square = func() -> Variant:
		if world.snapshot == null:
			return null
		var s := _screen_step(Vector2(0, 1)) * 2
		return world.snapshot.player_pos + Vector3i(s.x, s.y, 0)
	_sync_cheats_allowed()
	item_actions.backend = live
	live.events_arrived.connect(item_actions.on_events)
	world.applied.connect(func(snap: Snapshot, _n: int) -> void: item_actions.on_snapshot(snap))
	get_tree().auto_accept_quit = false   # closing the window saves first (_save_and_quit)
	# --live alone: continues the game in LIVE_WORLD (its first save), or starts one there if it has none.
	# --live --new: a new game in LIVE_WORLD, replacing it and its saves. --world=<name> and/or --save=<character>
	# load a saved game instead and never delete anything: --world alone takes its first save, --save alone
	# looks in LIVE_WORLD (or the -2, -3 ... worlds quick starts moved to: world_for_save). Saves live under
	# user://cdda/save/<world>/ (copy CDDA worlds there).
	var user_dir := cdda_user_dir if not cdda_user_dir.is_empty() else OS.get_user_data_dir().path_join("cdda")
	var data_dir: String = _args.get("cdda", _repo_path("cdda"))
	var ok := false
	if _args.has("world") or _args.has("save"):
		var w: String = _args.get("world", "")
		if w.is_empty():
			w = world_for_save(LiveSession.list_worlds(user_dir), _args.get("save", ""),
					func(n: String) -> PackedStringArray: return LiveSession.list_saves(user_dir, n))
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


## --save without --world: quick starts play in LIVE_WORLD, or in LIVE_WORLD-2, -3, ... when the bridge found
## LIVE_WORLD it didn't make (a player's or an older build's). The first of those (in that order) holding
## `save`, else LIVE_WORLD (the bridge then says the save isn't there).
static func world_for_save(worlds: PackedStringArray, save: String, saves: Callable) -> String:
	var nums: Array[int] = []
	for w in worlds:
		var tail := w.substr(LIVE_WORLD.length() + 1)
		if w.begins_with(LIVE_WORLD + "-") and tail.length() <= 4 and tail.is_valid_int() and tail[0] != "+" \
				and tail[0] != "-" and tail.to_int() >= 2:
			nums.append(tail.to_int())
	nums.sort()
	var order := PackedStringArray([LIVE_WORLD])
	for n in nums:
		order.append("%s-%d" % [LIVE_WORLD, n])
	for w in order:
		if not save.is_empty() and w in worlds and save in (saves.call(w) as PackedStringArray):
			return w
	return LIVE_WORLD


## --live without --world/--save/--quick: CDDA's main menu (MainMenu), then a new game (character creation
## through a `chargen` request, ChargenRequestWidget) or a load.
func _show_main_menu(data_dir: String, user_dir: String) -> void:
	main_menu = MainMenu.new()
	main_menu.test_range = LiveSession.test_range_available()   # set before setup() draws the page
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.add_child(main_menu)
	request_ui.get_parent().add_child(center)
	if LiveSession.delete_save_available():   # Load page: delete a character (and its world once empty)
		main_menu.deleter = func(w: String, sv: String) -> String: return live.delete_save(user_dir, w, sv, true)
	main_menu.relist = func() -> PackedStringArray: return LiveSession.list_worlds(user_dir)
	main_menu.setup(LiveSession.list_worlds(user_dir),
			func(w: String) -> PackedStringArray: return LiveSession.list_saves(user_dir, w))
	main_menu.new_game.connect(func(w: String, fresh: bool, chargen: bool, setup: bool) -> void:
		_menu_started(center, live.start_new_game(data_dir, user_dir, w, fresh, chargen, setup)))
	main_menu.load_game.connect(func(w: String, sv: String) -> void:
		_menu_started(center, live.start_load(data_dir, user_dir, w, sv)))
	main_menu.quit_requested.connect(_quit)
	_boot_log("main menu")
	main_menu.test_range_requested.connect(func() -> void:
		key_menu.cheats_forced = true   # cheats are always allowed in the range
		_sync_cheats_allowed()
		_menu_started(center, live.start_test_range(data_dir, user_dir)))
	status = "main menu"


func _menu_started(center: Control, ok: bool) -> void:
	if not ok:
		main_menu.set_message(live.error)
		return
	center.queue_free()
	main_menu = null
	_after_live_start(true)


## The bridge lets cheats work only while the player allowed them: the F1 debug switch, --test / --cheats, or a
## test-range game (KeyMenu.cheats_allowed).
func _sync_cheats_allowed() -> void:
	if live != null:
		live.set_cheats_allowed(key_menu.cheats_allowed())


## A test-range game, started from the menu or a range save loaded (`info` from LiveSession.range_changed):
## cheats are always allowed there, as the Test range start does, and pushed again, so the push made when the game
## reached running doesn't undo the bridge's opt-in for the range. True when it changed something.
static func range_forces_cheats(info: Dictionary, menu: KeyMenu, session: LiveSession) -> bool:
	var on: Variant = info.get("range")
	if menu == null or menu.cheats_forced or not (on is bool and on):
		return false
	menu.cheats_forced = true
	if session != null:
		session.set_cheats_allowed(menu.cheats_allowed())
	return true


## --test: the test kit, once, and only for a new game (never on a load: the save already has it).
## --cheats=a,b: those cheats on (names from LiveSession.CHEATS; others are named and skipped). Both also make
## the F1 menu's Cheats page available this session. Applied when the game first runs (after character creation).
func _apply_test_args(s: String) -> void:
	if s != "running" or _test_args_done:
		return
	_test_args_done = true
	if _args.has("test") and live.new_game:
		print("live: test kit " + ("asked for" if live.give_test_kit() else "refused"))
	if _args.has("cheats"):
		for n in cheat_names(String(_args["cheats"])):
			if n in LiveSession.CHEATS:
				if not live.set_cheat(n, true):
					push_warning("--cheats: %s refused" % n)
			else:
				push_warning("--cheats: unknown cheat \"%s\" (known: %s)" % [n, ", ".join(LiveSession.CHEATS)])


## The names in a --cheats= value: comma-separated, trimmed, at most 16, each cut to 32 characters.
static func cheat_names(v: String) -> PackedStringArray:
	var out := PackedStringArray()
	for n in v.left(1024).split(",", false):
		n = n.strip_edges().left(32)
		if not n.is_empty() and not n in out and out.size() < 16:
			out.append(n)
	return out


func _after_live_start(ok: bool) -> void:
	if ok:
		_boot_log("game booting")
		status = LiveSession.boot_text(live.boot_info())
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
	if _first_live_snapshot:
		_boot_log("first snapshot fetched and parsed (%d submaps)" % snap.submaps.size())
	world.submit(snap)


func _on_world_applied(snap: Snapshot, n: int) -> void:
	var first := _first_live_snapshot
	_first_live_snapshot = false
	_shown(snap, n, _submit_ms)
	fp.follow_square(snap.player_pos)   # also while outside, so V comes back to the player
	status = "turn %d: %s" % [snap.turn, status]
	if first:
		print("live: " + status)
		_boot_log("first world built")
		if not RenderingServer.frame_post_draw.is_connected(_on_first_frame_drawn):
			RenderingServer.frame_post_draw.connect(_on_first_frame_drawn, CONNECT_ONE_SHOT)
		_frame_player()


func _on_live_request(req: Dictionary) -> void:
	var door := GrabController.answer_for(grab.ask, req, Time.get_ticks_msec())
	if door.is_empty() and not grab.ask.is_empty() and not req.is_empty() and live.queued_actions() == 0:
		grab.ask = {}   # the dragged door's open / close went by without this prompt: never answer a later one
	if req.is_empty() or req.get("timed", false):
		request_ui.clear()   # the main loop: walking keys queue actions
		return
	var shot := aim.on_request(req)   # a projectile's shot request: answered at once, no UI
	if not shot.is_empty():
		# no UI and no time limit: a refused answer is replaced by a cancel, so CDDA never waits on it
		var sent := AimController.send_shot(shot, live.answer)
		if sent.is_empty():
			push_warning("live: bridge refused the shot answer %s and its cancel: the game may wait" % [shot])
		elif sent != shot and not _shot_refused:
			_shot_refused = true   # warned once
			push_warning("live: bridge refused the shot answer %s, cancelled it" % [shot])
		return
	print("live: request %s %s %s" % [req.get("kind", "?"), req.get("context", ""),
			str(req.get("text", "")).left(120).replace("\n", " ")])
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
	weather.on_events(events)   # lightning
	aim.hits.on_events(events)   # CDDA's hit confirmations: the crosshair's hit marker
	hud_data.on_events(events)
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
		# what the hands hold, used on the square you face (a hose + a container on a vehicle siphons); E only: a
		# stray left click must not fill, refuel or siphon
		act = "fp3d_use_" + OCT_ACTIONS[_octant(Vector2(0, 1))]
	elif InputActions.pressed(event, &"hold_off"):
		act = "fp3d_hold_off"
	elif InputActions.pressed(event, &"stow_off"):
		act = "fp3d_stow_off"
	elif InputActions.pressed(event, &"hand_off") or InputActions.pressed(event, &"hand_main"):
		# strike with the left (off) or right (main) hand: the creature under the crosshair when it is within
		# reach (an aimed strike, AimController.strike_action), else the square you face
		var hand := "off" if InputActions.pressed(event, &"hand_off") else "main"
		var facing: String = OCT_ACTIONS[_octant(Vector2(0, 1))]
		var cam := get_viewport().get_camera_3d()
		act = "fp3d_attack_%s_%s" % [hand, facing]
		if cam != null and world.snapshot != null:
			var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			act = aim.strike_action(hand, cam, aim.aim_point(cam, get_viewport().get_mouse_position(), captured),
					captured, world.snapshot.player_pos, facing)
	if act == "":
		return false
	if _in_main_loop():
		grab.ask = {}   # a key's own action: its prompts are the player's to answer
		live.queue_action(act)
	return true


## Look at (L / middle click): what is under the mouse (the screen centre while the mouse looks around), with a
## line from the player to it, its distance and what the snapshot says is there. The same key again closes it.
func _look_at_screen(pos: Vector2) -> Dictionary:
	if world.snapshot == null:
		return {}
	var r := _cast_screen(pos)
	_clear_look()
	if not r["hit"]:
		look_panel.text = "look: nothing there"
		return r
	var from := _look_from()
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
	_look_end = r["point"]
	_look_line = _line_mesh(from, _look_end)
	add_child(_look_line)
	return r


## The LookRay hit under screen point `pos` (the screen centre while the mouse looks around), "dir" added: the
## ray's direction. {hit: false} without a snapshot or camera.
func _cast_screen(pos: Vector2) -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if world.snapshot == null or cam == null:
		return {"hit": false}
	if look_ray == null:
		look_ray = LookRay.new(world)
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		pos = get_viewport().get_visible_rect().size / 2.0
	var v := eyes_view()
	var dir := cam.project_ray_normal(pos)
	var o := cam.project_ray_origin(pos)
	var s := ViewCamera.ray_start(str(v.get("mode", "")), o, dir, v.get("eye"))
	var r := look_ray.cast(s, dir, LookRay.MAX_M, true, not (v.get("mode", "") == "top" and s != o))
	r["dir"] = dir
	return r


## Cheat: teleport to the square under the crosshair (or the mouse, `pos`), through walls and between floors
## (TeleportAim picks the square, the bridge moves you). The op id (range_done says how it went), 0 when not sent.
func _teleport(pos: Vector2) -> int:
	if live == null or not live.can_teleport():
		status = "teleport: needs a running game with cheats allowed (F1 > HUD > Debug: cheats page)"
		return 0
	var r := _cast_screen(pos)
	var sq: Variant = TeleportAim.square(r, r.get("dir", Vector3.ZERO), world.coords.world_to_ms)
	if not sq is Vector3i:
		status = "teleport: point at a square in the loaded area"
		return 0
	var id := live.cheat_teleport(sq)
	status = "teleport: asked for" if id > 0 else "teleport: not sent (too many waiting)"
	if id > 0:
		if _teleport_ops.size() >= 32:
			_teleport_ops.clear()
		_teleport_ops[id] = true
	return id


## Where the look line starts: the chest (in first person a line from the eyes would run straight away from the view).
func _look_from() -> Vector3:
	if _fp_active():
		return fp.global_position - Vector3(0, 0.6, 0)
	return world.coords.ms_center_to_world(world.snapshot.player_pos) + Vector3(0, 1.0, 0)


## Keeps the look line's start on the player as they move; the end stays on the looked-at point.
func _update_look_line() -> void:
	if _look_line == null or world.snapshot == null:
		return
	var im := _look_line.mesh as ImmediateMesh
	var mat := im.surface_get_material(0)
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	im.surface_add_vertex(_look_from())
	im.surface_add_vertex(_look_end)
	im.surface_end()


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
		if not _in_main_loop():
			return false
		var used := StairUse.use_live(live.sim(), s)
		if used >= 0:
			status = ("stairs " + ("up" if s["dz"] > 0 else "down")) if used == 1 else "stairs: can't queue that now"
			return used == 1
		if not stairs_settled(live.queued_actions(), world.busy(), live.snapshot_seq, world.snapshot.seq):
			status = "stairs: wait for the last move to finish"
			return false
		var acts := StairUse.live_actions(world.snapshot.player_pos, s)
		if acts.is_empty():
			status = "stairs: walk next to them first"
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


## The steps toward a stair come from where the shown snapshot puts the player, so they are worked out only
## when nothing is queued and the world shows the newest snapshot.
static func stairs_settled(queued: int, world_busy: bool, fetched_seq: int, shown_seq: int) -> bool:
	return queued == 0 and not world_busy and fetched_seq == shown_seq


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
	viewmodel.sway_arcmin = aim.shown_dispersion
	viewmodel.visible = _fp_active() and view_mode == "first"
	viewmodel.set_item(world.snapshot.player_wielded if world.snapshot != null else 0, world.tables)
	viewmodel.set_dirt(int(world.snapshot.player_gun.get("dirt", -1)) if world.snapshot != null else -1)
	viewmodel.set_faults(world.snapshot.player_gun.get("faults", []) if world.snapshot != null else [])


func _in_main_loop() -> bool:
	return live.request.is_empty() or live.request.get("timed", false)


## The carried container with liquid in a hand (main hand first; the bridge's held state); null if none.
func _held_liquid() -> Variant:
	for h: String in ["main", "off"]:
		var it: Variant = hud_data.held.get(h)
		if it is ItemRef and not str(hud_data.held.get(h + "_liquid", "")).is_empty():
			return it
	return null


## Where holding E pours: into the container under the pointer, else onto the square you face.
func _pour_target() -> Dictionary:
	var t := grab.item_hover
	if not t.is_empty() and t.get("item") is ItemRef and (t["item"] as ItemRef).is_container(world.tables):
		return {"container": t["item"]}
	if world.snapshot == null:
		return {}
	var s := _screen_step(Vector2(0, 1))
	return {"square": world.snapshot.player_pos + Vector3i(s.x, s.y, 0)}


## E's tap with a liquid in hand: what E does otherwise (take the item under the pointer, else use / examine
## the square you face).
func _use_tap() -> void:
	if grab.take_hover() or live == null or not _in_main_loop():
		return
	grab.ask = {}
	live.queue_action("fp3d_use_" + OCT_ACTIONS[_octant(Vector2(0, 1))])


## Tab opens the inspect view: first person, in the main loop, no prompt, menu or held item in the way.
func _can_inspect() -> bool:
	return _fp_active() and world.snapshot != null and main_menu == null and not request_ui.visible \
			and not key_menu.visible and not grab.carrying() and grab.grabbed == null \
			and (live == null or _in_main_loop())


## The square hands and the mouse reach doors from: the player's; in mock first person, where you stand.
func _reach_square() -> Variant:
	if world.snapshot == null:
		return null
	if live == null and vr != null:   # mock VR: the hands reach from where the headset stands
		var at := world.coords.world_to_ms(vr.camera.global_position)
		return Vector3i(at.x, at.y, vr.z)
	if live == null and _fp_active():
		var sq := world.coords.world_to_ms(fp.position)
		return Vector3i(sq.x, sq.y, fp.z)
	return world.snapshot.player_pos


## A door leaf crossed its threshold (live): queue CDDA's open / close; its "where?" prompt is answered for it.
func _on_door_wants(square: Vector3i, open: bool) -> void:
	if live == null or world.snapshot == null or not _in_main_loop():
		return
	var act := grab.want(square, open, world.snapshot.player_pos, Time.get_ticks_msec())
	if act != "" and not live.queue_action(act):
		grab.ask = {}


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
	# The sun's aim and strength, the sky and the fog follow each snapshot's time and weather (WeatherView).
	weather = WeatherView.new()
	add_child(weather)
	weather.light_pass = world.lighting.enabled
	weather.lighting = world.lighting
	weather.setup(env, sun)
	weather.aim_sun(45.0, 0.0)


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
	hud_view = HudView.new()
	hud_view.data = hud_data
	layer.add_child(hud_view)
	request_ui = RequestUI.new()
	request_ui.direction_mapper = _screen_step
	request_ui.world_state = func() -> Array: return [world.snapshot, world.tables]
	request_ui.held = func() -> bool: return key_menu != null and key_menu.visible   # F1: its fields get the keys
	request_ui.answered.connect(_on_request_answered)
	request_ui.queue_after.connect(func(acts: PackedStringArray) -> void:
		for a in acts:
			if live != null:
				live.queue_action(a))
	layer.add_child(request_ui)
	key_menu = KeyMenu.new()
	key_menu.closed.connect(_on_key_menu_closed)
	key_menu.add_hud_settings(hud_settings)
	cheat_panel = CheatPanel.new()
	key_menu.cheats_forced = _args.has("test") or _args.has("cheats")
	key_menu.add_cheat_page(cheat_panel)
	key_menu.hud_changed.connect(func() -> void: compass.opacity = hud_settings.compass_opacity)
	key_menu.hud_changed.connect(_sync_cheats_allowed)   # the debug cheats switch
	layer.add_child(key_menu)


func _open_key_menu() -> void:
	camera.set_process_unhandled_input(false)
	fp.set_process_unhandled_input(false)
	key_menu.open()


func _on_key_menu_closed() -> void:
	if vr == null:
		_set_view(view_mode)   # cameras take their input again


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
	var typing := request_ui.wants_text_input() or key_menu.visible or inspect.visible   # no camera or walking
	camera.set_process(vr == null and not first_person and not typing)
	if vr == null and view_mode == "top" and fp.z != _top_z:   # top-down: the cut follows the player's level
		_top_z = fp.z
		world.set_view_z_max(fp.z)
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
	if typing or vr != null or (live != null and not _in_main_loop()):
		pour.cancel()   # a menu or prompt took the keys: its release won't come here
	elif pour.update(Time.get_ticks_msec()) == "refused":
		grab.flash("You can't pour that there.", true)
	creature_view.view_z_max = world.things_z_max()
	_place_player_body()
	_update_look_line()
	compass.heading_deg = Compass.heading_of(_view().global_basis)
	if compass.visible:   # creatures the player perceives, by bearing from the view
		compass.set_level_blips(Compass.level_blips(world.snapshot, _view().global_position,
				world.coords.ms_center_to_world))
	elif vr != null:   # the same blips on the VR wrist / belt compass (from the head)
		vr.compass.set_level_blips(Compass.level_blips(world.snapshot, _view().global_position,
				world.coords.ms_center_to_world))
	if vr != null:   # the VR Cheats page follows the F1 menu's gate (debug switch, --test / --cheats, test range)
		vr.cheats_allowed = key_menu != null and key_menu.cheats_allowed()
	var tile := world.coords.world_to_ms(_view().global_position)
	var view: String = {"first": "first person", "shoulder": "over the shoulder", "top": "top-down"}.get(view_mode,
			"outside, speed %.0f" % camera.speed)
	var help := _help()
	if live != null and live.state == "booting":   # the bridge's load phase, each frame (cheap)
		status = LiveSession.boot_text(live.boot_info())
	var lines := PackedStringArray([status, "%s  camera square %s  %s  roofs %s  %d fps" % [
			view, tile, world.level_text(), "on" if world.roofs_visible else "off",
			Engine.get_frames_per_second()], help])
	if vr != null:
		lines.append("VR level %d  controllers %s  settings: left menu button  %s" % [vr.z, vr.current_layout(),
				vr_perf.last_line])
	if live != null:
		lines.append(_act_help())
		lines.append("in hands: " + _wielded_name())
	# messages: hud_view's feed
	hud.text = "\n".join(lines)
	hud.visible = not key_menu.visible
	hud_view.visible = not key_menu.visible


## The view's key line, from the current bindings.
func _help() -> String:
	var k := InputActions.key_of
	var walk := _keys([&"move_forward", &"move_left", &"move_back", &"move_right"])
	var steps := _keys([&"step_forward", &"step_left", &"step_back", &"step_right"])
	var lv := "%s %s" % [k.call(&"level_down"), k.call(&"level_up")]
	var cut := "%s/%s" % [k.call(&"cutaway_up"), k.call(&"cutaway_down")]
	var out := "%s look  %s look at (again: close)  %s take, hold on a door and drag to open, hold on an item to carry it (wheel: nearer / farther)  %s take it  " % [
			k.call(&"look"), k.call(&"look_at"), k.call(&"click"), k.call(&"use_held")]
	if _fp_active():
		out += "%s inventory  " % k.call(&"inspect")
	if live != null and _fp_active():
		out += "%s or %s walk where you look  %s wait  %s stairs  prompts: mouse or keys, Esc cancels  %s cutaway  %s roofs  %s next view" % [
				walk, steps, k.call(&"wait"), lv, cut, k.call(&"roofs_toggle"), k.call(&"view_toggle")]
	elif live != null:
		out += "%s fly  %s/%s up/down  %s walk  %s wait  %s stairs  prompts: mouse or keys, Esc cancels  %s level  %s roofs  %s player  %s first person" % [
				walk, k.call(&"fly_up"), k.call(&"fly_down"), steps, k.call(&"wait"), lv, cut,
				k.call(&"roofs_toggle"), k.call(&"frame_player"), k.call(&"view_toggle")]
	elif _fp_active():
		out += "%s walk  %s fast  %s level down/up  %s cutaway  %s roofs  %s reload  %s player  %s next view" % [
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
	var p := pour.hint(world.tables)
	if not p.is_empty():
		parts.append(p)
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
	if key_menu.visible or inspect.visible:
		return   # the inspect view takes Tab / Esc itself (InspectView._input)
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.physical_keycode == InputActions.MENU_KEY:
		_open_key_menu()
		return
	if inspect.handle_key(event, _can_inspect()):
		return
	if vr == null and aim.handle_event(event, get_viewport().get_camera_3d()):
		return
	if vr == null and (live == null or _in_main_loop()) and pour.handle(event, Time.get_ticks_msec()):
		return   # E with a liquid in hand: waits for the release (a tap goes on below as usual) or a hold pours
	if vr == null and (live == null or _in_main_loop()) and grab.take_hovered(event):
		return   # E on an item you look at takes it (else E uses / examines, below)
	if vr == null and grab.handle_event(event, get_viewport().get_camera_3d(), _pointer()):
		return
	var wheel := event as InputEventMouseButton
	if vr == null and view_mode == "top" and wheel != null and wheel.pressed \
			and wheel.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		view_cam.zoom(-1 if wheel.button_index == MOUSE_BUTTON_WHEEL_UP else 1)   # top-down: the wheel zooms
		return
	if vr == null and InputActions.pressed(event, &"look_at"):
		if _look_line != null or (look_panel != null and not look_panel.text.is_empty()):
			_clear_look()   # the same key again closes it
		else:
			var mb := event as InputEventMouseButton
			_look_at_screen(mb.position if mb != null else get_viewport().get_mouse_position())
		return
	if vr == null and _fp_active() and InputActions.pressed(event, &"click"):
		# (doors and items under the pointer went to grab above, a target prompt to aim)
		var mb := event as InputEventMouseButton
		var hit := _cast_screen(mb.position if mb != null else get_viewport().get_mouse_position())
		var st: Dictionary = StairUse.find(world, hit["square"], _stair_z()) if hit.get("hit", false) else {}
		if not st.is_empty():   # clicking stairs in first person takes them
			use_stair(st)
		return   # a click on nothing does nothing (E uses what you hold on what you face)
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
	if live != null and InputActions.pressed(event, &"cheat_teleport"):
		_teleport(get_viewport().get_mouse_position())
		return
	if live != null and _live_action(event):
		return
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
		_clear_look()
	elif InputActions.pressed(event, &"cutaway_up"):
		world.step_view_z(1)
	elif InputActions.pressed(event, &"cutaway_down"):
		world.step_view_z(-1)
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
