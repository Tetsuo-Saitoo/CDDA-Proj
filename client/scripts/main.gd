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
const HUD_FIT_MS := 250   # the HUD text's room is measured no more often
const PAUSE_NOTE_MS := 1500   # a held move key repeats the "time is paused" note no faster
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
var _ride_look := [0, 0.0]     # [the vehicle the look turns with, its drawn yaw last frame] (_carry_look)
const DRIVE_VIEWS := HudSettings.DRIVE_VIEWS   # V while driving (flat screen); hud_settings.drive starts it
var _driving := false          # the last snapshot's player.driving
const VIEW_MODES := HudSettings.VIEWS
var _top_z := 0                # top view: the level cut at (follows the player's level)
var _stir_heading := NAN       # live item tiles: the view's heading last frame (a turn sloshes held liquids)
var _stir_pos: Variant = null  # the player's square at the last snapshot (a step sloshes them)
var _stir_step := 1.0          # each step rocks the other way
var sun: DirectionalLight3D
var weather: WeatherView       # C6 / I2: sky, sun and fog by CDDA's weather
var hud: Label
var request_ui: RequestUI
var main_menu: MainMenu
var key_menu: KeyMenu
var compass: Compass
var hud_settings := HudSettings.new()   # compass opacity (F1 menu, user://hud.cfg)
var look_panel: Label
var ride_hud: RideHud           # the driving HUD: speed gauge and vehicle panel while on a vehicle (flat screen)
var hands_panel: HandsPanel
var look_ray: LookRay
var _look_line: MeshInstance3D   # player -> what was clicked
var _look_end := Vector3.ZERO    # the looked-at point; the line's start follows the player (_update_look_line)
var gore: GoreView               # blood, gibs and bile fields on the ground
var fields_view: FieldView       # fire, sparks, smoke and gas fields
var vehicles_view: VehicleView   # CDDA's vehicles, part by part (C5)
var _cargo_lid: Array = []       # [vehicle uid, part]: the lid E opened with the tray (_open_cargo); shut when it closes
var gaze_fx: GazeEffects   # eyes adjust to light, peripheral unease (eye tracking; off until switched on)
var explosions: ExplosionView    # blasts, flashbangs, shockwaves from explosion events
var aim: AimController           # FPS aiming for target requests: crosshair, 3D picking, cursor marker
var grab: GrabController         # doors dragged with the mouse (E6), hover outline, hand pointer
var item_actions: ItemActions     # one-item take / put / drop for mouse and VR hands (E6 / L2 / L8)
var hands: Hands                  # the hands (mouse, VR controllers): targets, holding, letting go
var world_collision: WorldCollision   # E2 item physics: floor / wall / furniture boxes near the player
var item_bodies: ItemBodies           # E2 item physics: the items near the player as physics bodies
var item_placer: ItemPlacer           # E2 item physics: tells CDDA where a body came to rest (live game)
var mock_items: MockItems         # mock mode: item actions done on the client's own snapshot
var vise_bench: ViseBench       # V2: the gun in a bench vise and its mods (flat screen)
var inspect: InspectView         # Tab: hands, worn containers and the ground in reach; drag items between them
var hotbar: Hotbar                # G2: number keys put a set item type into the main hand
var hints: Hints                  # G6: one-time tips at the top right (flat screen)
var busy_note := BusyNote.new()   # "Time passes..." while the game runs on by itself (flat screen)
var hud_data := HudData.new()     # what the HUD shows (body, needs, held, messages, warnings), for screen and VR
var hud_view: HudView             # the screen view of hud_data
var classic: ClassicView          # F3: CDDA's own ASCII view of the snapshot around the player (G8, dev)
var character_data := CharacterData.new()   # the character screen's cards (G4), for screen and VR
var character: CharacterView      # P: the character screen
var work_view: VehicleWorkView    # Shift+V: C6 vehicle work beside a car (flat screen)
## C6: lead-world's work camera (camera/) once it lands: focus(uid, part), view(uid, name), leave(). Until then
## null and its calls do nothing (as VehicleView.highlight / open_hood until they exist).
var work_cam: Object = null
var work := VehicleWorkSession.new()   # C6: the work flow behind work_view and VR's work panel (lead-vr)
var _work_uid := 0                       # the vehicle the flat work view was opened on
var map_data := MapData.new()   # G5: the map's pages, for the screen map and VR's held map (lead-vr)
var map_view: MapView           # M: the map (flat screen)
var note_dialog: MapNoteDialog  # G5 slice 2 in VR: the flat note dialog on the VR panel (VrMap.open_note_dialog)
var pour := PourHold.new()        # E with a liquid in hand: a tap uses, a hold pours
var cheat_panel: CheatPanel       # the F1 menu's Cheats page (K7)
var mood_cue: MoodCue             # the mood's screen tint (G1), under the HUD
var hurt_cue: HurtCue             # the player's hurt at the view's edges (F3), over the mood's tint
var strain_cue: StrainCue         # the player's pain and low stamina at the view's edges (F3), under the hurt
var text_dock: TextKeysDock       # the on-screen keyboard for the focused text field (pad Y; the VR panel)
var _test_args_done := false      # --test / --cheats are applied once, when the game first runs
var viewmodel: WeaponViewmodel    # the wielded weapon, low right of the first-person view
var creature_view: CreatureView   # placeholder figures for NPCs and monsters (C4)
var item_looks: ItemLookView       # frost, heat, spoilage and liquid level on items lying near the player
var player_body: PlayerBody       # the player's own body and clothes (all views; head hidden in first person/VR)
var _demo_step := 0
var live: LiveSession
## Where CDDA keeps its saves and config; empty: user://cdda. Live scripts set it before adding main, so they
## never touch the player's saves.
var cdda_user_dir := ""
var vr: VrRig
var vr_perf: VrPerf
var flat_cook: VrCook   # E6: the pots' cooking cards on the flat screen (live, no headset); grab.cook picks them
var _quitting := false
var _saving_to_quit := false
var _save_asked := false   # the player's save (F5, closing the window), not an autosave
const SAVE_ON_QUIT_MS := 20000
var snapshot_path := ""
var status := ""
var _teleport_ops := {}   # op id -> true: teleports asked for, until range_done
var tele_pick := TeleportPick.new()   # the teleport cheat's look-at marker and click pick
## Eye tracking (user, 2026-11-19): where the player looks on the flat screen. No device yet: the base source tracks
## nothing, so every gaze feature is off and the game is as before (a desktop tracker's source replaces it later).
var gaze: GazeSource = GazeSource.new()
var eye_pause := EyePause.new()   # eye tracking 7: real time pauses while you look away
var eye_menus: EyeMenus           # eye tracking 6: menus by eye
var lean_peek := LeanPeek.new()   # 9: leaning to peek (flat keys here, VR's lean through lean / unlean)
var eye_view := EyeView.new()     # 1, 2 and the lean's tilt: the first-person view offset
var _lean_keys := 0               # the flat lean keys: -1 left, 1 right, 0 none
var _clock_ms := -1               # the HUD's time line: last read (ClockControl.text)
var _eye_check_ms := -1
var _look_marker: MeshInstance3D      # drawn on tele_pick.marked while the look is open
var back_out := BackOut.new()         # Esc / pad Start: one thing per press, then the game menu (_setup_back_out)
var _args := {}
var _log := PackedStringArray()
var _pause_note_ms := -PAUSE_NOTE_MS   # the last "time is paused" note for a dropped action (_held_by_pause)
var _hud_fit_ms := -HUD_FIT_MS   # the HUD text's fit (fit_index): when last measured, how many texts, the pick
var _hud_fit_n := 0
var _hud_pick := 0
var _step_ms := -STEP_REPEAT_MS
var _submit_ms := 0
var _first_live_snapshot := true
var _shot_refused := false   # a shot answer was refused (warned once)
## Back to the main menu after a game (_on_game_over): this Main hands over to a fresh one (`replaced`, then it is
## freed), so nothing of the ended game (state, timers, signals, workers) reaches the next. The fresh one opens on
## the menu (`open_menu`, whatever the command line asked for) showing `menu_message` (green when `menu_ok`).
signal replaced(fresh: Node3D)   # the fresh Main
const SCENE := "res://scenes/main.tscn"
var open_menu := false
var menu_message := ""
var menu_ok := false
var _leaving := false


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
	if not UserFiles.test_root().is_empty():   # a test or check run: its files aren't the player's
		print("user files: " + UserFiles.test_root())
	HudSettings.ensure_ambience_bus()   # G7: before the weather's players look for it
	snapshot_path = _args.get("snapshot", _repo_path("contracts/mock/snapshot_town.json"))
	world = WorldView.new()
	work.world = world   # C6: its snapshot and tables
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
	item_looks = ItemLookView.new()
	item_looks.name = "ItemLooks"
	item_looks.world = world
	add_child(item_looks)
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
	vehicles_view = VehicleView.new()
	add_child(vehicles_view)
	world.coords.origin_shifted.connect(vehicles_view.shift)
	work_cam = WorkCamera.new(vehicles_view)   # C6: the work view's camera (lead-world's; flat screen)
	add_child(work_cam)
	world.coords.origin_shifted.connect(work_cam.shift)
	work_cam.blocked = func(from: Vector3, to: Vector3, vehicle: int) -> float:   # it stands in front of walls
		if look_ray == null:
			look_ray = LookRay.new(world)
		return WorkCamera.free_way(look_ray, from, to, vehicle)
	fp.ride = func() -> Transform3D: return vehicles_view.ride_transform(world.snapshot)
	creature_view.seat = func(sq: Vector3i) -> Transform3D: return vehicles_view.seat_transform(world.snapshot, sq)
	view_cam.car = func() -> Variant: return vehicles_view.chase_target(world.snapshot)
	fp.recentre = _recentre_goal
	gaze_fx = GazeEffects.new()   # eye tracking, visual only: gaze set in _start_vr, switches by the settings
	gaze_fx.world = world
	gaze_fx.lighting = world.lighting
	gaze_fx.gaze = _flat_gaze   # the flat screen's eyes; _start_vr gives it the headset's
	add_child(gaze_fx)
	explosions = ExplosionView.new(world)
	add_child(explosions)
	world.coords.origin_shifted.connect(explosions.shift)
	request_ui.get_parent().add_child(explosions.flash_rect)
	aim = AimController.new(world, request_ui)
	aim.gaze = _flat_gaze   # eye tracking 5, throw where you look: the flat screen's eyes; _start_vr gives the headset's
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
	grab.context = _context_line
	aim.view = eyes_view    # and aiming: picks from in front of the player, bullets from the eyes
	item_actions = ItemActions.new()
	add_child(item_actions)
	item_actions.refused.connect(func(_it: ItemRef, op: String, why: String) -> void:   # F1: CDDA's no to a fit / take-off
		if vr == null and op in ["mod_add", "mod_remove"] and not why.is_empty() and not vise_bench.clamped():
			grab.flash(why, true))   # (at the vise its panel says it: ViseBench.on_refused)
	hands = Hands.new(world, item_actions)
	# car storage: letting go over a cargo space puts the item in; on the flat screen always (no hand opens a lid),
	# in VR only with its lid open (lead-world's VehicleView.can_reach; lead-vr's rule)
	hands.cargo_reach = func(uid: int, part: int) -> bool: return vr == null or vehicles_view.can_reach(uid, part)
	add_child(hands)
	grab.hands = hands
	var tray := ItemTray.new()   # L8: the mouse's tray (`loot_tray`); VR has its own (VrRig.tray)
	tray.world = world
	tray.hands = hands
	add_child(tray)
	grab.tray = tray
	tray.closed.connect(func(_why: String) -> void: _shut_cargo_lid())
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
		item_looks.body_slot = item_bodies.slot   # items in reach are bodies: their state shells follow them
		# Slices 3-4: a body at rest somewhere new is told to CDDA (bridge ops "spot" / "place"). Inert until the
		# live session has place_item / spot_item (the mock has neither): nothing is sent, bodies behave as before.
		item_placer = ItemPlacer.new()
		item_placer.bodies = item_bodies
		item_placer.centre = func() -> Variant: return world.snapshot.player_pos if world.snapshot != null else null
		item_placer.busy = item_actions.pending   # nothing is told about an item a hand's take / drop is under way on
		item_placer.refused.connect(func(_uid: int, why: String) -> void:   # CDDA wouldn't move it: its reason
			if why.is_empty():
				return
			hud_data.on_events([MockItems.message_event(why)])
			if vr != null:
				vr.refused_here(why))
		add_child(item_placer)
	pour.actions = item_actions
	pour.held = _held_liquid
	pour.target = _pour_target
	pour.tap = _use_tap
	inspect = InspectView.new(hands, item_actions)
	request_ui.get_parent().add_child(inspect)
	request_ui.get_parent().move_child(inspect, request_ui.get_index())   # prompts and F1 draw over it
	inspect.character = character_data   # G2: carried weight and volume against the limits, from the sheet
	vise_bench = ViseBench.new()   # V2: E on a bench vise in reach with the gun wielded: the gun in it, its mods beside
	vise_bench.actions = item_actions
	vise_bench.world = world
	vise_bench.model_parent = world
	vise_bench.jaws = func(uid: int) -> Variant: return Vise.jaws(hands.picker, uid)
	request_ui.get_parent().add_child(vise_bench)
	request_ui.get_parent().move_child(vise_bench, inspect.get_index())   # prompts and the Tab view draw over it
	vise_bench.released.connect(func(why: String) -> void:
		if not why.is_empty():
			grab.flash(why))
	item_actions.refused.connect(vise_bench.on_refused)
	hotbar = Hotbar.new()   # G2: 3..9 and 0 put a set item type into the main hand; set in the Tab view
	hotbar.world = world
	hotbar.actions = item_actions
	var hb_why := hotbar.load_file()
	if hb_why != "":
		push_warning("hotbar: " + hb_why)
	request_ui.get_parent().add_child(hotbar)
	request_ui.get_parent().move_child(hotbar, inspect.get_index())   # under the Tab view and the prompts
	inspect.hotbar = hotbar
	inspect.opened.connect(func() -> void:
		hotbar.show_empty = true
		ItemTileView.stir(ItemTileView.OPEN_STIR)   # the liquids in the rows settle as it opens
		if hints != null:
			hints.trigger("inspect" if vr == null else "vr_inspect"))
	inspect.closed.connect(func() -> void: hotbar.show_empty = false)
	inspect.opened.connect(_ask_character)
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
	viewmodel.flashes = hud_settings.weather_flash   # muzzle flashes follow the flash setting
	viewmodel.left_handed = hud_settings.left_handed()   # a left-hander's gun rests on the left
	fp.add_child(viewmodel)
	aim.shot_went.connect(viewmodel.kick)   # a round CDDA fired: recoil and muzzle flash
	aim.hits.misfired.connect(viewmodel.click)   # a trigger pull with no round: a dry click
	aim.hits.player_hurt.connect(hurt_cue.hurt)   # damage to the player: a red edge, fading
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
	if live != null and vr == null:   # E6: cooking by the crosshair (the headset has its own cards: VrRig.cook)
		flat_cook = VrCook.flat(world, fp, live)
		add_child(flat_cook)
		grab.cook = flat_cook
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
	if _args.has("vr-check") and vr != null:   # automated checks in a real VR session (VrCheck)
		var vc := VrCheck.new()
		vc.rig = vr
		vc.quit = _quit
		vc.mock_of = func() -> MockItems: return mock_items
		add_child(vc)
		vc.run(str(_args["vr-check"]))


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
	if item_placer != null:
		item_placer.clear()
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
	item_looks.apply(snap)
	if hands != null:
		hands.dress_held()   # the copies in hands wear their items' states too
	gore.view_z_max = world.things_z_max()
	gore.apply(snap, world)
	fields_view.view_z_max = world.things_z_max()
	fields_view.apply(snap, world)
	vehicles_view.view_z_max = world.things_z_max()
	vehicles_view.apply(snap, world)
	_driving_view(snap.player_driving)
	player_body.apply(snap, world.tables)
	inspect.refresh()
	hud_data.update(snap, world.tables)
	character_data.update(hud_data, snap, world.tables)
	# Each new turn while shown (refused while the last one is still out); the Tab view shows what is carried from
	# the same sheet.
	if character.visible or inspect.visible:
		_ask_character()
	work.follow(snap)   # C6: closed when the vehicle went, asked again when its parts or what is carried change
	map_data.follow(snap)   # G5: the player's cell; a new one reads its page again
	if hotbar != null:
		hotbar.refresh()   # G2: which slots are carried or in hand now
	if hands_panel != null:
		hands_panel.refresh_tiles()   # the held items' states came with this snapshot
	if _stir_pos != null and _stir_pos != snap.player_pos:   # a step: held liquids rock
		_stir_step = -_stir_step
		ItemTileView.stir(ItemTileView.STEP_STIR * _stir_step)
	_stir_pos = snap.player_pos
	if hints != null and live != null and _in_main_loop():
		if vr == null:
			hints.trigger("start")   # G6: once, ever (seen ids are kept)
		else:
			for id in Hints.VR_START:   # VR: its own first-turn hints, one after another
				hints.trigger(id)
		for id in Hints.due(snap, hud_data):   # the first hostile, hunger or thirst, bleeding, tiredness
			var shown_id: String = id if vr == null else Hints.vr_id(id)   # VR: its own words; "" when VR has none yet
			if shown_id != "":
				hints.trigger(shown_id)
	classic.show_world(snap, world.tables)
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
		vr.go_to_player(vr.body_square())   # during a peek: the body's square, not the peeked one
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


## C5, VrRig.ride: the vehicle the player is on, [uid, where VehicleView draws it now, where the snapshot puts it
## (its pose once the glide has arrived: VehicleView.target_of)]; [] when none or not drawn.
func _vr_ride() -> Array:
	var s := world.snapshot
	var at := s.vehicle_at(s.player_pos) if s != null and vehicles_view != null else []
	if at.is_empty():
		return []
	var uid := (at[0] as Snapshot.Vehicle).uid
	var d: Variant = vehicles_view.drawn(uid)
	var to: Variant = vehicles_view.target_of(uid)
	if not d is Transform3D or not to is Transform3D:
		return []
	return [uid, d, to]


## The driving view after `m` (V while driving): first person -> chase -> top-down -> first person; any other: first.
static func next_drive_view(m: String) -> String:
	return DRIVE_VIEWS[(DRIVE_VIEWS.find(m) + 1) % DRIVE_VIEWS.size()]


## Driving starts (player.driving): the driving view; it ends: back to the walking view (flat screen only).
func _driving_view(driving: bool) -> void:
	if driving == _driving:
		return
	_driving = driving
	view_cam.driving = driving and vr == null
	if vr == null:
		_set_view(hud_settings.drive if driving else hud_settings.view)


## C5 recentre: driving in first person on the flat screen with the F1 switch on, the yaw of the vehicle's heading
## as drawn (FirstPersonCamera eases the look back to it after a moment without look input); null otherwise.
func _recentre_goal() -> Variant:
	if vr != null or not _driving or view_mode != "first" or not hud_settings.recentre or vehicles_view == null:
		return null
	var c: Variant = vehicles_view.chase_target(world.snapshot)
	var h := ViewCamera.heading_yaw(c) if c is Transform3D else NAN
	return h if is_finite(h) else null


## C5, flat screen: the look turns with the vehicle the player is on as it is drawn turning (VR: VrRide turns the
## rig instead).
func _carry_look() -> void:
	var uid := 0
	var heading := 0.0
	var s := world.snapshot
	if vr == null and s != null and vehicles_view != null:
		var at := s.vehicle_at(s.player_pos)
		var d: Variant = vehicles_view.drawn((at[0] as Snapshot.Vehicle).uid) if not at.is_empty() else null
		if d is Transform3D:
			uid = (at[0] as Snapshot.Vehicle).uid
			heading = car_yaw(d)
	if uid != 0 and uid == _ride_look[0] and is_finite(heading):
		var turn := wrapf(heading - float(_ride_look[1]), -PI, PI)
		if absf(turn) > 1e-6:
			fp.set_look(fp.yaw + turn, fp.pitch)
	_ride_look = [uid, heading]


## C5: the real-footprint marks of the vehicle the player is in aren't shown from its first-person seat (flat first
## person, VR), nor in VR those of the vehicle whose model the head is in; every other view and vehicle shows them.
func _hide_own_marks() -> void:
	var s := world.snapshot
	var uid := 0
	if s != null and vehicles_view != null and (vr != null or view_mode == "first"):
		var at := s.vehicle_at(s.player_pos)
		uid = (at[0] as Snapshot.Vehicle).uid if not at.is_empty() else 0
	var head := Vector3.INF
	var cam := get_viewport().get_camera_3d() if vr != null else null
	if cam != null:
		head = cam.global_position
	if vehicles_view != null:
		vehicles_view.hide_marks(uid, head)


## A vehicle's yaw as drawn (radians about up, as FirstPersonCamera.yaw turns: + to the left).
static func car_yaw(xf: Transform3D) -> float:
	var x := xf.basis.x
	return atan2(-x.z, x.x) if Vector2(x.x, x.z).length() > 1e-4 else 0.0


## First person and VR: the body stands under the eyes and turns with them, head hidden. Outside: on the
## player's square (on a gliding vehicle, where it is drawn: ride_transform), facing the way first person last looked.
func _place_player_body() -> void:
	if world.snapshot == null:
		player_body.visible = false
		return
	var from: Variant = world.snapshot.player_peeking_from   # CDDA's peek: the eyes are on the peeked square
	var own := vr != null or (first_person and view_mode == "first" and from == null)
	player_body.show_head = not own
	var at := world.coords.ms_center_to_world(world.snapshot.player_pos)
	var yaw := fp.yaw
	if vr != null:
		at = Vector3(vr.camera.global_position.x, vr.floor_y(), vr.camera.global_position.z)
		yaw = vr.camera.global_rotation.y
	elif from is Vector3i:
		at = world.coords.ms_center_to_world(from)   # the body stays on its own square
	elif first_person:
		at = fp.base_position() - Vector3(0, FirstPersonCamera.EYE_H, 0)
	elif vehicles_view != null:
		var r := vehicles_view.ride_transform(world.snapshot)
		at = r * at if r.is_finite() else at
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
	if not m in VIEW_MODES and m != "chase":   # chase: only while driving (_driving_view, _toggle_view)
		m = "first"
	var was_top := view_mode == "top"
	view_mode = m
	_set_first_person(m != "outside")
	if m in ViewCamera.MODES:
		view_cam.mode = m
		view_cam.chase_heading = NAN   # a new chase starts behind the vehicle at once
		view_cam.top_yaw = NAN         # and a new top view turned as it should be
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
	if _driving:   # driving: first person -> chase -> top-down
		_set_view(next_drive_view(view_mode))
		hud_settings.drive = view_mode
	else:
		_set_view(VIEW_MODES[(VIEW_MODES.find(view_mode) + 1) % VIEW_MODES.size()])
		if view_mode == "outside":
			_frame_outside(fp.base_position() - Vector3(0, FirstPersonCamera.EYE_H, 0))
		hud_settings.view = view_mode
	var err := hud_settings.save_file()
	if err != OK:
		push_warning("view not saved: %s" % error_string(err))


## The headset view (block L1). OpenXR only starts when Godot runs with --xr-mode on.
## G6 in VR: the rig draws the flat Hints' hint in VR words and asks for its VR-only ones (both made: once each).
func _vr_hints() -> void:
	if vr == null or hints == null:
		return
	vr.hint.source = hints
	if not vr.hint_due.is_connected(hints.trigger):
		vr.hint_due.connect(hints.trigger)


func _start_vr() -> void:
	var xr := XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized():
		status = "VR: OpenXR isn't running. Start Godot with --xr-mode on, with the headset's runtime (SteamVR, Meta) on"
		push_error(status)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)   # the headset paces the frames
	get_viewport().use_xr = true
	vr = VrRig.new(world, VrSettings.from_args(_args, VrSettings.load_file()))
	VehicleView.signs_upright(true)   # C5 marks: no roll, no per-eye turn in the headset
	weather.flash_scale = WeatherView.FLASH_VR   # a full-view flash is harsher in a headset
	vr.save_path = VrSettings.FILE
	vr.body = player_body   # one hand system: the body's arms reach for the VR hands
	vr.ride = _vr_ride   # C5: standing on the player's vehicle, the rig rides along as it glides
	vr.ride_square = vehicles_view.square_at   # ... while the head is over one of its cells as drawn
	vr.drive.interior = vehicles_view.interior   # VR driving by hand: the wheel and the lids (VrDrive)
	vr.drive.open_lid = vehicles_view.open_lid
	vr.drive.open_hood = vehicles_view.open_hood   # C6: the hood by its handle
	vr.work.anchors = vehicles_view.part_anchors   # C6 by hand: the part an empty hand is on, lit (VrWork)
	vr.work.highlight = vehicles_view.highlight
	vr.work.ray = func(o: Vector3, d: Vector3, m: float) -> Dictionary: return hands.look_ray.cast(o, d, m, false)
	vr.work_session = work   # ... and the trigger on it: CDDA's commands on a wheel (VrWorkMenu)
	vr.pull.part_copy = vehicles_view.part_copy   # ... and the grip on it: the part pulled out by hand (VrPartPull)
	vr.pull.hide_part = vehicles_view.hide_part
	vr.work.square = vehicles_view.mount_at   # ... and a part's item held to a square: installed there (VrInstall)
	vr.work.light_square = vehicles_view.highlight_square
	vr.map.make_canvas = func() -> Control:   # G5: the map held in VR, its own view on the shared MapData (VrMap)
		var c := MapCanvas.new()
		c.data = map_data
		c.center_on_player()
		return c
	vr.drive.can_reach = vehicles_view.can_reach   # car storage by hand: the tray on an open trunk (VrDrive.cargo_at)
	vr.drive.square_at = vehicles_view.square_at
	vr.looking.teleport_to = _teleport_to   # VR look at (left X held): the main trigger's cheat teleport to the ring
	vr.eye_on = hud_settings.eye_on   # F1 > Eye tracking: the tracker, zoom, labels, menus, lean (read each frame)
	vr.on_lean = lean   # VR leaning (VrLean): a sideways head tilt asks for CDDA's peek that way; held 250 ms here
	vr.on_unlean = unlean
	vr.time_pause = toggle_time_pause   # the VR menu's Time row: pause real time or go on (a hostile's auto-pause too)
	gaze_fx.gaze = vr.look   # the eyes when tracked (VrRig.look); head gaze or no tracker: the effects stay off
	aim.gaze = vr.look   # throw where you look: only the tracked eyes count (AimController refuses the head's gaze)
	vr.gaze_throw_square = aim.gaze_square   # a thrown item or the main trigger's throw goes where the eyes look
	vr.gaze_throw_request = aim.throw_at_gaze   # the main trigger answers a CDDA throw request there
	vr.compass.opacity = hud_settings.compass_opacity
	vr.hud.data = hud_data   # body, needs, warnings, messages inside the off forearm
	vr.hands = hands   # the controllers are hands "vr_l" / "vr_r"; reach is the picker's (grab.reach)
	vr.cheats_backend = live   # K7: the VR menu's Cheats page (null in the mock; hidden until LiveSession has cheats())
	vr.cheats_allowed = key_menu != null and key_menu.cheats_allowed()   # kept in step each frame (_process)
	vr.cook.backend = live   # L9: recipe matches over pots on the heat (once LiveSession has match_recipes)
	vr.gun.aim = aim   # L2 guns by hand: fired from the muzzle (fire_from, live_aim), haptics on shots and kills
	vr.gun.flashes = hud_settings.weather_flash   # its muzzle flash follows the flash setting too
	vr.hurt.source = hurt_cue   # F3: the flat cue's level and setting, as a red edge in the headset
	vr.busy.source = busy_note   # "Time passes..." low in the headset's view while the game runs on
	_vr_hints()
	aim.hits.player_hurt.connect(vr.hurt.hurt)   # and a short buzz in both hands
	vr.gun.actions = item_actions   # magazine out / in by hand (unload / reload)
	vr.mouth.actions = item_actions   # food or a drink brought to the mouth: CDDA's consume
	vr.aid.actions = item_actions   # first aid brought to a body part: CDDA's consume on that part
	vr.gun.queue_action = func(a: String) -> bool: return live != null and _in_main_loop() and _queue_act(a)
	vr.wheel.request_ui = request_ui   # radial menus by hand: CDDA's menu as a wheel around the hand
	vr.wheel.queue_action = vr.gun.queue_action
	vr.drive.queue_action = vr.gun.queue_action   # the wheel's steer and the pedals: CDDA's driving actions
	vr.drive.paused = func() -> String:   # real time paused: say so in the headset, send nothing
		return VrRig.vr_words(ClockControl.held_note()) \
				if live != null and live.state == "running" and ClockControl.paused(live.clock()) else ""
	vr.wheel.list_only = func() -> bool: return hud_settings.context_menu == HudSettings.MENU_LIST
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
	vr_perf.settings_of = func() -> Dictionary: return vr.settings
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
	# L4: the screen's menus on the VR panel (laser clicks, the stick's ui_* actions; RequestUI.as_key), in their
	# drawing order: the Tab view, CDDA's prompts, the F1 menu, the main menu when it is up, the on-screen keys.
	# Each is a direct child of the panel's root (the panel shows while one of them is visible), drawn larger.
	var panel := panel_root(vr)
	if panel != null:
		menus_to_panel(panel, [inspect, character, key_menu, main_menu.get_parent() if main_menu != null else null],
				PANEL_UI_SCALE)
		request_ui.reparent(panel, false)
		if inspect.get_parent() == panel:   # prompts draw over the Tab view, under the F1 menu
			panel.move_child(request_ui, inspect.get_index() + 1)
		request_ui.set_ui_scale(PANEL_UI_SCALE)   # 16 px text -> ~22 px: readable at the panel's distance
		request_ui.keyboard = true   # no keyboard in the headset: text prompts open with TextKeys
		text_dock.reparent(panel, false)   # ... and the other text fields get them from the dock
		text_dock.auto = true
		text_dock.ui_scale = PANEL_UI_SCALE
		if "open_note_dialog" in vr.map:   # G5 slice 2: VR's map notes a cell with the flat dialog, typed on the dock
			note_dialog = MapNoteDialog.new()
			note_dialog.data = map_data
			panel.add_child(note_dialog)
			panel.move_child(note_dialog, request_ui.get_index())   # under CDDA's prompts
			PanelFit.apply(note_dialog, PANEL_UI_SCALE)
			vr.map.open_note_dialog = func(cell: Vector3i) -> void: note_dialog.open_on(cell)
	if vr.has_signal("ui_asked"):   # the VR menu's rows for the F1 menu and the Tab view
		vr.connect("ui_asked", open_ui)
	print("VR on: %s" % vr.settings)
	_apply_clock()   # VR always runs in real time (PLAN.md); a game already running switches now


## Moves the screen menus in `menus` (Controls; others skipped) under the VR panel's root, in order, each drawn
## `k` times larger (PanelFit).
static func menus_to_panel(panel: Control, menus: Array, k: float) -> void:
	for m: Variant in menus:
		if m is Control and is_instance_valid(m):
			(m as Control).reparent(panel, false)
			PanelFit.apply(m, k)


## Opens a menu by name for a view without keys (the VR menu's rows): "keys" the F1 menu, "inventory" the Tab
## view (when it may open: in the main loop, nothing else up). True when it is open now.
func open_ui(which: String) -> bool:
	match which:
		"keys":
			if not key_menu.visible and not inspect.visible:
				_open_key_menu()
			return key_menu.visible
		"inventory":
			if not inspect.visible and _can_inspect():
				inspect.open()
			return inspect.visible
		"character":
			if not character.visible and _can_open_character():
				character.open()
			return character.visible
	return false


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


## What the flat screen's compass reads: the camera drawing it (lead-world's chase, shoulder and top views while
## driving, first person, the usual camera), else `fallback`.
static func drawn_view(cam: Camera3D, fallback: Node3D) -> Node3D:
	return cam if cam != null and is_instance_valid(cam) else fallback


## Whether the driving HUD shows for `r` (player.vehicle_state): only on a vehicle, unless F1 turned it off; at the
## controls in first person (`first_person_cam`: that camera draws), driving or not, the car's own dashboard shows
## the speed, so only with F1 > HUD > Gauge in first person (the user, 2026-11-21).
static func ride_shown(r: RideInfo, settings: HudSettings, first_person_cam: bool) -> bool:
	return r.ok and settings.ride_hud and (not (first_person_cam and (r.driver or r.at_controls)) or settings.ride_hud_fp)


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
	live.character_sheet.connect(character_data.set_sheet)   # G4: the character screen's stats, skills ...
	work.live = live
	live.vehicle_work.connect(work.on_read)   # C6: the work read
	map_data.live = live
	live.overmap.connect(map_data.on_page)   # G5: a map page
	live.events_arrived.connect(map_data.on_events)   # G5 slice 2: map_result, the answer to a note write
	live.events_arrived.connect(work.on_events)   # C6: the work action's work_result
	live.state_changed.connect(func(s: String) -> void:
		if s != "running":
			character_data.set_sheet(null)   # another game, another character
			map_data.reset())   # G5: another game, another map
	live.cheats_changed.connect(hud_data.set_cheats)
	live.cheats_changed.connect(cheat_panel.on_cheats_changed)
	live.state_changed.connect(_apply_test_args)
	live.state_changed.connect(func(s: String) -> void:   # real time or turns, auto-pause: each new or loaded game
		if s == "running":
			_apply_clock())
	live.state_changed.connect(inspect.on_game_state)   # a Tab batch stops when the game does
	live.state_changed.connect(_on_game_over)   # died, saved and quit, failed: back to the main menu
	key_menu.quit_to_menu.connect(_quit_to_menu)
	key_menu.show_quit_to_menu(true)
	cheat_panel.backend = live
	live.range_changed.connect(cheat_panel.on_range_changed)
	live.range_changed.connect(func(i: Dictionary) -> void: range_forces_cheats(i, key_menu, live))
	live.range_done.connect(cheat_panel.on_range_done)
	live.range_done.connect(func(id: int, err: String) -> void:
		if _teleport_ops.erase(id):
			status = "teleport: done" if err.is_empty() else "teleport: " + err)
	cheat_panel.teleport = func() -> int:   # the F1 entry: the square at the screen's centre
		return _teleport(get_viewport().get_visible_rect().size / 2.0)
	cheat_panel.pick_teleport = start_teleport_pick   # the F1 entry: the next click picks the square
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
	item_actions.asking = func() -> bool: return not _in_main_loop()   # a consume's question: no timeout meanwhile
	live.events_arrived.connect(item_actions.on_events)
	if item_placer != null:
		item_placer.backend = live
		live.events_arrived.connect(item_placer.on_events)   # item_result: the answer to a place / spot op
	world.applied.connect(func(snap: Snapshot, _n: int) -> void: item_actions.on_snapshot(snap))
	world.applied.connect(func(_snap: Snapshot, _n: int) -> void: vise_bench.on_snapshot())   # V2: walked off, unwielded
	get_tree().auto_accept_quit = false   # closing the window saves first (_save_and_quit)
	# --live alone: continues the game in LIVE_WORLD (its first save), or starts one there if it has none.
	# --live --new: a new game in LIVE_WORLD, replacing it and its saves. --world=<name> and/or --save=<character>
	# load a saved game instead and never delete anything: --world alone takes its first save, --save alone
	# looks in LIVE_WORLD (or the -2, -3 ... worlds quick starts moved to: world_for_save). Saves live under
	# user://cdda/save/<world>/ (copy CDDA worlds there).
	var user_dir := cdda_user_dir if not cdda_user_dir.is_empty() else ProjectSettings.globalize_path(UserFiles.at("user://cdda"))
	var data_dir: String = _args.get("cdda", _repo_path("cdda"))
	var ok := false
	if open_menu:   # after a game: the menu, never the command line's quick start or save again
		_show_main_menu(data_dir, user_dir)
		main_menu.set_message(menu_message, menu_ok)
		return
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
	if panel_root(vr) != null:   # on the VR panel: drawn larger, like the other menus there
		PanelFit.apply(center, PANEL_UI_SCALE)
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
	main_menu.options_requested.connect(func() -> void: open_ui("keys"))
	_boot_log("main menu")
	main_menu.test_range_requested.connect(func() -> void:
		key_menu.cheats_forced = true   # cheats are always allowed in the range
		_sync_cheats_allowed()
		_menu_started(center, live.start_test_range(data_dir, user_dir)))
	status = "main menu"


## The game ended (the character died, CDDA's save and quit) or failed: back to the main menu, in a fresh Main
## (deferred: this runs inside LiveSession's poll). Not while quitting (closing the window ends the program), in
## a --screenshot or --vr-check run, or after a stop() of our own ("stopped").
func _on_game_over(s: String) -> void:
	if (s != "ended" and s != "failed") or _quitting or _saving_to_quit or _leaving or _args.has("screenshot") \
			or _args.has("vr-check"):
		return
	var said := game_over_text(s, live.error)
	_back_to_menu.call_deferred(said[0], said[1])


## What the main menu says after a game: [text, ok]. `error` is LiveSession.error (CDDA's reason, plain text). A
## cancelled character creation or world setup is no error: just the menu ("character creation cancelled" was the
## bridge's word for it before the "cancelled" ending).
static func game_over_text(state: String, error: String) -> Array:
	match error:
		"cancelled", "character creation cancelled":
			return ["", false]
		"saved and quit":
			return ["Game saved.", true]
		"the character died":
			return ["Your character died.", false]
		"the game ended", "":
			return ["The game ended.", false]
	return [("The game failed: %s" if state == "failed" else "The game ended: %s") % error.left(300), false]


## Hands over to a fresh Main showing the main menu with `text`, in this one's place (the scene's current scene
## too), and frees this one: its _exit_tree and its children's let the game's workers finish first (the snapshot
## parse, the world's meshing; LiveSession.stop on a game that is over returns at once). The two caches shared
## across Mains are emptied: item meshes and the wet ground.
func _back_to_menu(text: String, ok: bool) -> void:
	if _leaving or not is_inside_tree():
		return
	_leaving = true
	grab.cook = null   # the flat cooking cards stop before the LiveSession goes
	if is_instance_valid(flat_cook):
		flat_cook.standalone = false
		flat_cook.backend = null
		flat_cook.queue_free()
	flat_cook = null
	var fresh := (load(SCENE) as PackedScene).instantiate() as Node3D
	var fields := {"cdda_user_dir": cdda_user_dir, "open_menu": true, "menu_message": text, "menu_ok": ok}
	for k: String in fields:   # by name: main.gd has no class_name to type `fresh` with
		fresh.set(k, fields[k])
	ItemVisual.clear_cache()
	TerrainMesher.wet_ground(0.0)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE   # the game may have captured it; the menu needs it
	var parent := get_parent()
	var at := get_index()
	var current := get_tree().current_scene == self
	parent.remove_child(self)
	parent.add_child(fresh)
	parent.move_child(fresh, at)
	if current:
		get_tree().current_scene = fresh
	print("live: back to the main menu (%s)" % text)
	replaced.emit(fresh)
	queue_free()


## F1's "Save and quit to menu": CDDA's own save and quit (it asks "Save and quit?" first); once the game has
## ended, _on_game_over brings the main menu back.
func _quit_to_menu() -> void:
	if live == null or live.state != "running" or not _in_main_loop() or not live.queue_action("save"):
		status = "can't save and quit now (the game isn't waiting for a move)"


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
	busy_note.on_snapshot(snap)   # "Sleeping...", "Waiting..." while the game runs on
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
	busy_note.on_request(req, Time.get_ticks_msec())
	var door := GrabController.answer_for(grab.ask, req, Time.get_ticks_msec())
	if door.is_empty() and not grab.ask.is_empty() and not req.is_empty() and live.queued_actions() == 0:
		grab.ask = {}   # the dragged door's open / close went by without this prompt: never answer a later one
	lean_peek.request_seen(req)
	var peek: Variant = lean_peek.on_request(req)   # 9: the lean's own peek: held with no UI, or closed
	if peek != null:
		request_ui.clear()
		if not (peek as Dictionary).is_empty() and not live.answer(peek):
			push_warning("live: bridge refused the peek's cancel")
		return
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
	elif hints != null and not str(req.get("kind", "")) in ["chargen", "world_setup"]:
		hints.trigger("prompt" if vr == null else "vr_prompt")   # G6: the first question from the game in play


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


## Radial menus: the crosshair line for the furniture in the square you face (live, flat screen, in play).
func _context_line() -> String:
	if live == null or vr != null or world.snapshot == null or not _in_main_loop():
		return ""
	var v := _vise_under()
	if v > 0:   # V2: what E does on a bench vise with the gun wielded
		return "%s: %s" % [InputActions.key_of(&"use_held"), "take the gun back" if v == vise_bench.vise_uid
				else "clamp the gun in the vise"]
	var p := GunModFit.held_pair(hud_data.held.get("main"), hud_data.held.get("off"), world.snapshot, world.tables)
	if not p.is_empty():   # F1: what E does with the gun and a gunmod in hand
		return "%s: fit the %s" % [InputActions.key_of(&"use_held"),
				InventoryModel.clean((p["mod"] as ItemRef).display_name(world.tables))]
	var s: Vector2i = OCT_STEPS[_octant(Vector2(0, 1))]
	return ContextPrompt.text(world.snapshot, world.tables, world.snapshot.player_pos + Vector3i(s.x, s.y, 0),
			hud_settings.context_menu)


func _octant(dir: Vector2) -> int:
	var v := _view()
	# first person: the look itself, not the eye-tracking view offset (steps go where you face)
	return octant_for(Basis.from_euler(Vector3(fp.pitch, fp.yaw, 0.0)) if v == fp else v.global_basis, dir)


## Octant of a step key's (right, forward) direction: where you look, or while driving CDDA's own driving keys
## (forward UP speeds up, back DOWN slows down, left / right steer), whichever way the camera faces.
func _step_octant(dir: Vector2) -> int:
	if world.snapshot != null and world.snapshot.player_driving:
		return octant_for(Basis.IDENTITY, dir)
	return _octant(dir)


## CDDA's control_vehicle on a vehicle square without controls does nothing and says nothing: say why.
const NO_CONTROLS_NOTE := "There are no controls here: sit at the vehicle's controls to drive."


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
	for i in Hotbar.SLOTS:   # G2: a set item type into the main hand; why not goes to the message feed
		if hotbar != null and InputActions.pressed(event, Hotbar.action(i)):
			if _in_main_loop():
				var why := hotbar.use(i)
				if why != "":
					hud_data.on_events([MockItems.message_event(why)])
			return true
	var act := ""
	for a: StringName in InputActions.STEPS:
		if InputActions.pressed(event, a):
			act = OCT_ACTIONS[_step_octant(InputActions.STEPS[a])]
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
		# strike with the left or right hand (main or off by HudSettings.main_hand): the creature under the crosshair when it is within
		# reach (an aimed strike, AimController.strike_action), else the square you face
		var hand := HudSettings.hand_for("left" if InputActions.pressed(event, &"hand_off") else "right",
				hud_settings.left_handed())
		var facing: String = OCT_ACTIONS[_octant(Vector2(0, 1))]
		var cam := get_viewport().get_camera_3d()
		act = "fp3d_attack_%s_%s" % [hand, facing]
		if cam != null and world.snapshot != null:
			var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			act = aim.strike_action(hand, cam, aim.aim_point(cam, get_viewport().get_mouse_position(), captured),
					captured, world.snapshot.player_pos, facing)
	if act == "control_vehicle" and _in_main_loop() and world.snapshot != null and not world.snapshot.player_driving \
			and world.snapshot.controls_at(world.snapshot.player_pos, world.tables) == Snapshot.NO_CONTROLS:
		hud_data.on_events([MockItems.message_event(NO_CONTROLS_NOTE)])
	if act == "eat" and _in_main_loop():
		var food := _held_consumable()
		if food != null and item_actions.consume(food):
			return true   # what a hand holds is eaten or drunk, no menu (else CDDA's eat menu, below)
	if act == "":
		return false
	if _in_main_loop():
		grab.ask = {}   # a key's own action: its prompts are the player's to answer
		var sent := _queue_act(act)
		# E: the object's menu, if any, as a wheel; only once E's own action is on its way (request_ui.note_input
		# undoes it when another key comes first)
		if sent and InputActions.pressed(event, &"use_held") and vr == null \
				and hud_settings.context_menu != HudSettings.MENU_LIST:
			request_ui.want_wheel(WHEEL_WAIT_MS, hud_settings.context_menu == HudSettings.MENU_HOLD)
	return true


## A hand or key action out to CDDA; a strike at a square (AimController.strike_square: a knight's move off, or a
## smash at the wall, door or furniture under the crosshair) goes by queue_action_at, and one whose square is gone
## isn't sent.
func _queue_act(act: String) -> bool:
	if _held_by_pause():
		return false
	if act == AimController.AT_ACTION or act == AimController.SMASH_AT:
		var sq: Variant = aim.strike_square(act)
		return sq is Vector3i and live.queue_action_at(AimController.cdda_action(act), sq)
	return live.queue_action(act)


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
	if live != null and live.can_teleport():   # the cheat: J goes to the look's square while it is open
		tele_pick.marked = TeleportAim.square(r, r.get("dir", Vector3.ZERO), world.coords.world_to_ms)
		if tele_pick.marked is Vector3i:
			lines.append(tele_pick.look_line(InputActions.key_of(&"cheat_teleport")))
			_look_marker = _marker_mesh(world.coords.ms_center_to_world(tele_pick.marked))
			_look_marker.position.y = world.ground_y(_look_marker.position, (tele_pick.marked as Vector3i).z) + 0.03
			add_child(_look_marker)
	look_panel.text = "\n".join(lines)
	_look_end = r["point"]
	_look_line = _line_mesh(from, _look_end)
	add_child(_look_line)
	return r


## The LookRay hit under screen point `pos` (the screen centre while the mouse looks around), "dir" added: the
## ray's direction. {hit: false} without a snapshot or camera. `creatures` false: the ray passes through them.
## In VR the gaze instead (VrRig.look: eyes or head), whatever `pos` says.
func _cast_screen(pos: Vector2, creatures := true) -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if world.snapshot == null or cam == null:
		return {"hit": false}
	if look_ray == null:
		look_ray = LookRay.new(world)
	if vr != null:   # VR: where the player looks (the eyes when tracked, else the head: VrRig.look)
		var g := vr.look()
		if g.is_empty():
			return {"hit": false}
		var hit := look_ray.cast(g["from"], g["dir"], LookRay.MAX_M, creatures)
		hit["dir"] = g["dir"]
		return hit
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		pos = get_viewport().get_visible_rect().size / 2.0
	var v := eyes_view()
	var dir := cam.project_ray_normal(pos)
	var o := cam.project_ray_origin(pos)
	var s := ViewCamera.ray_start(str(v.get("mode", "")), o, dir, v.get("eye"))
	var r := look_ray.cast(s, dir, LookRay.MAX_M, creatures, not (v.get("mode", "") == "top" and s != o))
	r["dir"] = dir
	return r


## Cheat: teleport to the square under the crosshair (or the mouse, `pos`), through walls and between floors, past
## creatures (TeleportAim picks the square, the bridge moves you). The op id (range_done says how it went), 0 when
## not sent.
func _teleport(pos: Vector2) -> int:
	if live == null or not live.can_teleport():
		status = "teleport: needs a running game with cheats allowed (F1 > HUD > Debug: cheats page)"
		return 0
	var r := _cast_screen(pos, false)   # zombies all around must not stop the aim
	var sq: Variant = TeleportAim.square(r, r.get("dir", Vector3.ZERO), world.coords.world_to_ms)
	if not sq is Vector3i:
		status = "teleport: point at a square in the loaded area"
		return 0
	return _teleport_to(sq)


## Cheat: teleport to square `sq` (the bridge picks the nearest free square if it is taken).
func _teleport_to(sq: Vector3i) -> int:
	if live == null or not live.can_teleport():
		status = "teleport: needs a running game with cheats allowed (F1 > HUD > Debug: cheats page)"
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
		if _held_by_pause():
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
	tele_pick.marked = null
	if _look_marker != null:
		_look_marker.queue_free()
		_look_marker = null


## The teleport marker: a flat ring on the floor of a square, drawn over everything (zombies around it too).
static func _marker_mesh(at: Vector3) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.albedo_color = Color(0.35, 0.85, 1.0)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.3
	ring.outer_radius = 0.38
	ring.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "TeleportMarker"
	mi.mesh = ring
	mi.position = at
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


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
	aim.gaze_throw = hud_settings.eye_on("throw_look")   # F1 > Eye tracking; off with the tracker switch (opt-in)
	aim.update(get_viewport().get_camera_3d(), Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	var t := request_ui.target_widget()
	viewmodel.aimed = t != null and TargetRequestWidget.is_attack_mode(t.mode)
	viewmodel.sway_arcmin = aim.shown_dispersion
	viewmodel.visible = _fp_active() and view_mode == "first" and not vise_bench.clamped()   # V2: the gun is in the vise
	viewmodel.set_item(world.snapshot.player_wielded if world.snapshot != null else 0, world.tables)
	viewmodel.set_dirt(int(world.snapshot.player_gun.get("dirt", -1)) if world.snapshot != null else -1)
	viewmodel.set_faults(world.snapshot.player_gun.get("faults", []) if world.snapshot != null else [])
	viewmodel.suppressed = world.snapshot != null and world.snapshot.player_gun.get("suppressed", false) == true
	viewmodel.set_mods(GunMods.mods_of(world.snapshot.player_gun if world.snapshot != null else null))


## Eye tracking 7: a few times a second, EyePause decides from the gaze (looking at the screen or not) and the sim's
## clock; only the pause or resume goes to the bridge. Nothing is asked of the bridge without a gaze that can tell.
func _eye_away_pause(now_ms: int) -> void:
	if live == null or live.state != "running" or (_eye_check_ms >= 0 and now_ms - _eye_check_ms < 250):
		return
	_eye_check_ms = now_ms
	var look: Variant = gaze.on_screen() if vr == null else null
	if not look is bool and not eye_pause.paused_by_eyes:
		return
	match eye_pause.step(hud_settings.eye_on("away_pause"), look, live.clock(), now_ms):
		EyePause.PAUSE:
			if live.set_paused(true):
				status = "paused: you looked away"
		EyePause.RESUME:
			live.set_paused(false)


func _in_main_loop() -> bool:
	return live.request.is_empty() or live.request.get("timed", false)


## What a hand holds that CDDA eats, drinks or takes, or holds such (a bottle of water), main hand first; null if
## none (ItemActions.consumable).
func _held_consumable() -> ItemRef:
	for h: String in ["main", "off"]:
		var it: Variant = hud_data.held.get(h)
		if it is ItemRef and ItemActions.consumable(it, world.snapshot, world.tables):
			return it
	return null


## F1 (gun modification on the flat screen): E with the gun wielded and a gunmod in the off hand fits it
## (ItemActions.mod_add: CDDA's install, its questions as prompts, its odds and time); a "no" CDDA already gave
## (wielded_gun `fits`) shows by the crosshair instead. False when the hands don't hold that pair (E goes on as usual).
func _fit_held_mod() -> bool:
	var p := GunModFit.held_pair(hud_data.held.get("main"), hud_data.held.get("off"), world.snapshot, world.tables)
	if p.is_empty():
		return false
	var mod: ItemRef = p["mod"]
	var gun: ItemRef = p["gun"]
	var why := GunModFit.refusal(world.snapshot, mod.uid, InventoryModel.clean(gun.display_name(world.tables)))
	if why != "":
		grab.flash(why, true)
	elif item_actions.mod_add(mod, gun):
		grab.flash(GunModFit.fitting_line(world.snapshot, mod.uid, InventoryModel.clean(mod.display_name(world.tables))))
	else:
		grab.flash("You can't fit that now.", true)
	return true


## V2 (gun modification at a bench vise, flat screen): the bench vise under the pointer that lies in reach (Vise.near)
## while the gun is wielded; -1 if none.
func _vise_under() -> int:
	if vr != null or world.snapshot == null or grab.carrying() or grab.item_hover.is_empty():
		return -1
	var it: Variant = grab.item_hover.get("item")
	var t := world.tables.index_of("itype", Vise.ITEM) if world.tables != null else -1
	if not it is ItemRef or t <= 0 or (it as ItemRef).type != t \
			or not GunModFit.is_wielded_gun(hud_data.held.get("main"), world.snapshot) \
			or not (it as ItemRef).uid in Vise.near(world.snapshot, world.tables):
		return -1
	return (it as ItemRef).uid


## V2: E on a bench vise in reach with the gun wielded puts the gun in its jaws with its mods beside it (ViseBench);
## E on that vise again takes it back. False when the pointer isn't on such a vise (E goes on as usual).
func _clamp_at_vise() -> bool:
	var v := _vise_under()
	if v <= 0:
		return false
	if vise_bench.clamped():
		var same := v == vise_bench.vise_uid
		vise_bench.release()
		if same:
			return true
	var cam := get_viewport().get_camera_3d()
	var across := cam.global_basis.x if cam != null else Vector3.RIGHT
	if not vise_bench.clamp_gun(v, hud_data.held.get("main"), Vise.jaws(hands.picker, v), across):
		grab.flash("You can't clamp your gun now.", true)
	return true


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


## Car storage (the coordinator's rule, 2026-11-21): E on a vehicle's cargo space next to you (a trunk, a glovebox,
## a truck bed; Snapshot.Vehicle.cargo lists those) opens its lid, if it has one (lead-world's VehicleView.open_lid,
## the client's own: CDDA has none), and the tray lays out what CDDA lists in it, in one step; closing the tray
## shuts the lid. Looking sends nothing; taking goes through Hands as from any tray. False when E isn't on one:
## E goes on as before (CDDA's own use / examine).
## C6: Shift+V opens the work view on the vehicle next to the player (the one pointed at first). Flat screen.
func _open_work() -> void:
	if world.snapshot == null or (live != null and not _in_main_loop()):
		return
	var hit := _cast_screen(_pointer(), false) if get_viewport().get_camera_3d() != null else {}
	var at: Variant = hit.get("square") if hit.get("hit", false) else null
	var veh := VehicleWorkData.vehicle_near(world.snapshot, at if at is Vector3i else Vector3i.MAX)
	if veh == null:
		grab.flash("No vehicle next to you.")
		return
	_work_uid = veh.uid
	if work_cam != null and is_instance_valid(work_cam) and "frame_x" in work_cam:   # the part left of the view
		work_cam.frame_x = VehicleWorkView.free_center(get_viewport().get_visible_rect().size.x)
	work_view.fit()
	work_view.open(veh.uid, veh.name)
	if not work.open(veh.uid):
		work_view.close()
		grab.flash("The vehicle is out of reach.")


## The flat work view drives main.work (VehicleWorkSession: the reads, the actions, the hold), and shows what it
## says. VR's work panel drives the same session (lead-vr); the highlight, hood and work camera are main's for both.
func _wire_work() -> void:
	work_view.part_selected.connect(work.select)
	work_view.command_chosen.connect(func(cmd: String, row: int) -> void: work.send(cmd, row))
	work_view.view_chosen.connect(work.view)
	work_view.install_asked.connect(_on_work_install)
	work_view.install_chosen.connect(func(vpart: int, at: Vector2i) -> void: work.install(vpart, at))
	work_view.install_ended.connect(work.end_install)
	work_view.closed.connect(_on_work_view_closed)
	work.result.connect(func(r: Dictionary) -> void: work_view.set_result(r))   # ignored unless it shows that vehicle
	work.said.connect(_on_work_said)
	work.started.connect(_on_work_started)
	work.moved.connect(_on_work_moved)
	work.part_focused.connect(_on_work_part)
	work.square_focused.connect(_on_work_square)
	work.view_chosen.connect(_on_work_view)
	work.closed.connect(_on_work_closed)


## Whether the flat view shows the session's vehicle.
func _flat_work() -> bool:
	return work.uid != 0 and work_view.visible and work_view.uid == work.uid


func _on_work_said(text: String) -> void:
	if _flat_work():
		work_view.say(text)


func _on_work_started(cmd: String) -> void:
	if not _flat_work():
		return
	if cmd == "i":
		work_view.end_install()   # the new part is the vehicle's last row once the work is done
	elif cmd == "o":
		work_view.forget_selection()   # the rows after a removed part move up


func _on_work_moved() -> void:
	if _flat_work():
		work_view.forget_selection()


func _on_work_part(row: int) -> void:
	call_if(vehicles_view, "highlight", [work.uid, row])
	if row >= 0:
		call_if(work_cam, "focus", [work.uid, row])


func _on_work_square(at: Vector2i) -> void:
	call_if(vehicles_view, "highlight_square", [work.uid, at])
	call_if(work_cam, "focus_square", [work.uid, at])


func _on_work_view(which: String) -> void:
	var hood: Variant = call_if(vehicles_view, "open_hood", [work.uid, which == "hood"])
	if which == "hood" and hood == false:
		work.say("This vehicle has no engine bay to open.")
	call_if(work_cam, "view", [work.uid, which])


## Install mode asked for its square's types (and the picked type's lines): read from the game only (the snapshot's
## stand-in knows nothing of CDDA's install rules).
func _on_work_install(at: Vector2i, vpart: int) -> void:
	if not work.show_install(at, vpart):
		work_view.end_install()
		work_view.say(VehicleWorkSession.NO_INSTALL)


func _on_work_view_closed() -> void:
	if work.uid != 0 and work.uid == _work_uid:
		work.close()


## The session closed (by a presenter, or the vehicle went or is out of reach: `why` says so).
func _on_work_closed(vehicle: int, why: String) -> void:
	call_if(vehicles_view, "highlight", [vehicle, -1])
	call_if(vehicles_view, "open_hood", [vehicle, false])
	call_if(work_cam, "leave", [])
	if work_view.visible and work_view.uid == vehicle:
		work_view.close()
	if not why.is_empty():
		grab.flash(why)


## Calls `method` on `o` when it has one (another lead's call that may not have landed yet) and returns what it
## returns; null otherwise.
static func call_if(o: Object, method: String, args: Array) -> Variant:
	if o != null and is_instance_valid(o) and o.has_method(method):
		return o.callv(method, args)
	return null


func _open_cargo() -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam == null or world.snapshot == null or grab.tray_open() or grab.carrying():
		return false
	var hit := _cast_screen(_pointer(), false)
	if not hit.get("hit", false) or not hit.get("square") is Vector3i or not hit.has("vehicle"):
		return false
	var src := ItemTray.source_for_cargo(world.snapshot, hit["square"])
	if src.is_empty() or src["vehicle"] != hit["vehicle"]:
		return false
	var veh: Snapshot.Vehicle = world.snapshot.vehicle_at(hit["square"])[0]
	var label := VehicleView.part_label(world.snapshot, world.tables, veh, src["part"])
	if not grab.open_tray_src(src, cam.global_transform, "Nothing in the %s." % label):
		return true   # E was on it: the note says it's empty
	vehicles_view.open_lid(src["vehicle"], src["part"], true)
	_cargo_lid = [src["vehicle"], src["part"]]
	return true


func _shut_cargo_lid() -> void:
	if _cargo_lid.size() == 2:
		vehicles_view.open_lid(_cargo_lid[0], _cargo_lid[1], false)
	_cargo_lid = []


## E's tap with a liquid in hand: what E does otherwise (take the item under the pointer, else use / examine
## the square you face).
func _use_tap() -> void:
	if grab.take_hover() or live == null or not _in_main_loop():
		return
	if _held_by_pause():
		return
	grab.ask = {}
	live.queue_action("fp3d_use_" + OCT_ACTIONS[_octant(Vector2(0, 1))])


## Tab opens the inspect view: first person or VR, in the main loop, no prompt, menu or held item in the way.
## The character screen may open: a world is shown, no menu or CDDA prompt is up.
## G4: asks the game for the character sheet (stats, skills, traits ...); the screen says it's waiting until the
## first one comes. Nothing without a live game or with an older DLL.
func _ask_character() -> void:
	if live != null and live.query_character() > 0:
		character_data.set_waiting(true)


func _can_open_character() -> bool:
	return world.snapshot != null and main_menu == null and not request_ui.visible and not key_menu.visible \
			and not inspect.visible


func _can_inspect() -> bool:
	return (_fp_active() or vr != null) and world.snapshot != null and main_menu == null and not request_ui.visible \
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
		var sq := world.coords.world_to_ms(fp.base_position())
		return Vector3i(sq.x, sq.y, fp.z)
	return world.snapshot.player_pos


## A door leaf crossed its threshold (live): queue CDDA's open / close; its "where?" prompt is answered for it.
func _on_door_wants(square: Vector3i, open: bool) -> void:
	if live == null or world.snapshot == null or not _in_main_loop() or _held_by_pause():
		return
	if live.can_act_at():   # CDDA takes exactly this square; one it refuses never falls back to its own pick
		live.open_at(open, square, world.snapshot.player_pos)
		return
	var act := grab.want(square, open, world.snapshot.player_pos, Time.get_ticks_msec())   # older DLLs: answer "where?"
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
	if mv == Vector2.ZERO or not _in_main_loop() or Input.is_key_pressed(KEY_SHIFT) or Input.is_key_pressed(KEY_ALT):
		return
	var t := Time.get_ticks_msec()
	if not now and (t - _step_ms < STEP_REPEAT_MS or live.queued_actions() > 0):
		return
	if _held_by_pause():
		_step_ms = t   # a held key asks again at the step rate, not every frame
		return
	live.queue_action(OCT_ACTIONS[_step_octant(mv)])
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
	world.coords.origin_shifted.connect(weather.shift)
	weather.aim_sun(45.0, 0.0)


const BASE_LOOK := 0.003
const WHEEL_WAIT_MS := 1500   # E on an object: CDDA's menu arriving this soon after shows as a wheel   # the cameras' own look speed, radians per pixel


## G7 options: the volume on the Master bus (headset too); the look speed, invert Y and field of view on the
## flat-screen cameras; the 3D render scale, vsync and
## fullscreen on the window (not with the headset, which sets its own, nor for a screenshot or headless).
func _apply_options() -> void:
	var o := hud_settings
	if view_cam != null:
		view_cam.top_up = o.top_up if o.top_up in ViewCamera.TOP_UPS else "heading"
	_apply_clock()   # the F1 Time row
	if gaze_fx != null:   # eye tracking 4 and 8 (lead-world's GazeEffects): their switches
		gaze_fx.adapt_on = o.eye_on("light_adapt")
		gaze_fx.unease_on = o.eye_on("unease")
	for c: Camera3D in [fp, view_cam, camera]:
		if c != null:
			var f := HudSettings.clamp_to(o.fov, HudSettings.FOVS, HudSettings.DEFAULT_FOV)
			if c is FirstPersonCamera:
				(c as FirstPersonCamera).base_fov = f   # its zoom (eye tracking) goes on top
			else:
				c.fov = f
	var speed := BASE_LOOK * HudSettings.clamp_to(o.look_speed, HudSettings.LOOK_SPEEDS, 1.0)
	if fp != null:
		fp.sensitivity = speed
		fp.invert_y = o.invert_y
	if camera != null:
		camera.sensitivity = speed
		camera.invert_y = o.invert_y
	HudSettings.set_bus_loudness(0, o.volume)   # Master (bus 0): every sound, the Ambience bus's too
	HudSettings.set_bus_loudness(AudioServer.get_bus_index(HudSettings.AMBIENCE_BUS), o.ambience_volume)
	if vr != null or _args.has("vr") or _args.has("screenshot") or DisplayServer.get_name() == "headless":
		return
	get_viewport().scaling_3d_scale = HudSettings.clamp_to(o.render_scale, HudSettings.RENDER_SCALES, 1.0)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if o.vsync else DisplayServer.VSYNC_DISABLED)
	var full := DisplayServer.window_get_mode() in [DisplayServer.WINDOW_MODE_FULLSCREEN,
			DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
	if full != o.fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if o.fullscreen
				else DisplayServer.WINDOW_MODE_WINDOWED)


## G7: the menus' and the HUD's size (the window's content scale; the 3D view keeps its pixels), at start and when
## the F1 menu closes, not while its slider moves (the menu would move under the mouse). Not with the headset (its
## panels are their own viewports), for a screenshot or headless.
func _apply_ui_scale() -> void:
	if vr != null or _args.has("vr") or _args.has("screenshot") or DisplayServer.get_name() == "headless":
		return
	get_window().content_scale_factor = HudSettings.clamp_to(hud_settings.ui_scale, HudSettings.UI_SCALES, 1.0)


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	mood_cue = MoodCue.new()   # first: everything else draws over it
	mood_cue.data = hud_data
	layer.add_child(mood_cue)
	strain_cue = StrainCue.new()   # pain and low stamina: over the mood's tint, under the hurt's
	strain_cue.data = hud_data
	layer.add_child(strain_cue)
	hurt_cue = HurtCue.new()   # over the mood's tint, under everything else
	hurt_cue.world = world
	layer.add_child(hurt_cue)
	hud = hud_label()
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
	mood_cue.enabled = hud_settings.mood_cues
	hurt_cue.enabled = hud_settings.hurt_cues
	strain_cue.enabled = hud_settings.hurt_cues
	weather.flash_enabled = hud_settings.weather_flash
	weather.quality = hud_settings.weather_quality   # G7, lead-world's setting (clamped there too)
	hud_data.set_feed_hidden(hud_settings.feed_hidden)
	_apply_options()
	_apply_ui_scale()
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
	ride_hud = RideHud.new()   # under the hands panel and the menus
	layer.add_child(ride_hud)
	hands_panel = HandsPanel.new()
	hands_panel.left_handed = hud_settings.left_handed()
	hands_panel.tile_of = func(uid: int) -> Dictionary:   # live item tiles behind the held items
		return ItemTile.for_item(world.snapshot, world.tables, uid)
	layer.add_child(hands_panel)
	hud_view = HudView.new()
	hud_view.data = hud_data
	layer.add_child(hud_view)
	classic = ClassicView.new()
	layer.add_child(classic)
	character = CharacterView.new()
	character.data = character_data
	character.opened.connect(_ask_character)
	layer.add_child(character)
	map_view = MapView.new()
	map_view.data = map_data
	map_view.blocked = func() -> bool: return request_ui != null and request_ui.visible   # CDDA's prompts first
	layer.add_child(map_view)
	work_view = VehicleWorkView.new()
	work_view.blocked = func() -> bool: return request_ui != null and request_ui.visible   # CDDA's prompts first
	work_view.type_name = func(vp: int) -> String:   # the id table's name for a part type
		var def := VehicleView.def_of(world.tables, world.snapshot, vp)
		return def.name if def != null else ""
	layer.add_child(work_view)
	_wire_work()
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
	hints = Hints.new()   # G6: one-time tips (the first turn, the first Tab view, the first question)
	hints.persist = get_tree().get_script() == null   # a test runner's SceneTree script: never the player's file
	var hints_why := hints.load_file() if hints.persist else ""   # nor read it: runs are the same everywhere
	if hints_why != "":
		push_warning("hints: " + hints_why)
	layer.add_child(hints)
	_vr_hints()
	layer.add_child(busy_note)
	key_menu.add_hints(hints)
	cheat_panel = CheatPanel.new()
	key_menu.cheats_forced = _args.has("test") or _args.has("cheats")
	key_menu.add_cheat_page(cheat_panel)
	key_menu.hud_changed.connect(func() -> void:
		hud_data.set_feed_hidden(hud_settings.feed_hidden)
		compass.opacity = hud_settings.compass_opacity
		mood_cue.enabled = hud_settings.mood_cues
		hurt_cue.enabled = hud_settings.hurt_cues
		strain_cue.enabled = hud_settings.hurt_cues
		weather.flash_enabled = hud_settings.weather_flash
		weather.quality = hud_settings.weather_quality
		if viewmodel != null:
			viewmodel.flashes = hud_settings.weather_flash
		if vr != null:
			vr.gun.flashes = hud_settings.weather_flash
			viewmodel.left_handed = hud_settings.left_handed()
		if hands_panel != null:
			hands_panel.left_handed = hud_settings.left_handed()
		if _driving and vr == null and view_mode != hud_settings.drive:   # F1's driving view, picked while driving
			_set_view(hud_settings.drive)
		_apply_options())
	key_menu.hud_changed.connect(_sync_cheats_allowed)   # the debug cheats switch
	layer.add_child(key_menu)
	text_dock = TextKeysDock.new()   # last: over the menus, and first to get the pad while it shows
	layer.add_child(text_dock)
	_setup_back_out()
	_setup_eye_menus()


## What Esc / pad Start backs out of, one per press (BackOut.ORDER); the parts are read when the key comes.
## Eye tracking 6: the pointer follows the eyes in a menu, `gaze_click` clicks there (EyeMenus). Added last, so it
## sees that key before the menus do.
func _setup_eye_menus() -> void:
	eye_menus = EyeMenus.new()
	eye_menus.gaze = gaze
	eye_menus.allowed = func() -> bool: return vr == null and hud_settings.eye_on("menus") and _menu_open()
	add_child(eye_menus)


## A menu or prompt has the mouse: the F1 menu, the Tab view, the character screen, a prompt / list / wheel, the
## tray, the vise panel, the main menu.
## Leaning to peek (eye tracking 9, needs no tracker; the flat lean keys and lead-vr's physical lean): toward the
## neighbouring square `d` (x east, y south). Held LeanPeek.HOLD_MS in a live game, CDDA's peek looks from there.
## False when the lean switch is off or d isn't one of the 8 ways.
func lean(d: Vector2i) -> bool:
	return hud_settings.eye_on("lean") and lean_peek.lean(d, Time.get_ticks_msec())


## Ends the lean; an open peek closes (its request is cancelled).
func unlean() -> void:
	var a := lean_peek.unlean()
	if not a.is_empty() and live != null and not live.answer(a):
		push_warning("live: bridge refused the peek's cancel")


## Eye tracking on the flat screen: the lean keys and the peek they lead to (9), zoom where you look while
## `zoom_look` is held (1) and seeing past a screen edge (2), as one view offset on the first-person camera. The eyes
## only turn the view; the peek's square is all that reaches the game.
func _eye_view_step(now_ms: int) -> void:
	var shown := vr == null and _fp_active() and view_mode == "first"
	if vr == null:   # VR leans through lean() / unlean() (lead-vr)
		var side := 0
		if shown and not _menu_open():
			side = int(Input.is_action_pressed(&"lean_right", true)) - int(Input.is_action_pressed(&"lean_left", true))
		if side != _lean_keys:
			if _lean_keys != 0:
				unlean()
			_lean_keys = side if side != 0 and lean(LeanPeek.WAYS[_octant(Vector2(side, 0))]) else 0
	if lean_peek.leaning() and not hud_settings.eye_on("lean"):
		unlean()
		_lean_keys = 0
	if live != null and world.snapshot != null:
		var sq: Variant = lean_peek.peek_square(now_ms, _in_main_loop(), world.snapshot.player_pos)
		if sq != null:
			lean_peek.sent(not _held_by_pause() and live.queue_action_at("peek", sq))
	if fp == null:
		return
	var look: Variant = null
	var edge: Variant = null
	if shown and gaze.tracked() and not _menu_open():
		var p: Variant = gaze.screen_point()
		var size := get_viewport().get_visible_rect().size
		if hud_settings.eye_on("zoom") and GazeSource.point_in(p, size) != null:
			look = EyeView.angles(Basis.from_euler(Vector3(fp.pitch, fp.yaw, 0.0)), fp.project_ray_normal(p))
		if hud_settings.eye_on("edge_turn"):
			edge = EyeView.on_screen(p, size)
	var zoom := shown and hud_settings.eye_on("zoom") and Input.is_action_pressed(&"zoom_look", true)
	var o := eye_view.step(look, edge, zoom, _lean_keys if shown else 0, lean_peek.peeking())
	fp.set_view_offset(o[0], o[1], o[2], o[3], o[4])


## The flat screen's gaze for GazeEffects: {from, dir, eyes} through the first-person view; {} in other views, in a
## menu or while the eyes aren't tracked (main's `gaze`).
func _flat_gaze() -> Dictionary:
	if vr != null or not _fp_active() or view_mode != "first" or _menu_open():
		return {}
	var r := gaze.ray(fp)
	if not r.is_empty():
		r["eyes"] = true
	return r


## Real time or turns and auto-pause on the running game (ClockControl): the flat screen's settings, VR always
## real time. At each game start or load, VR start and any HUD setting change.
func _apply_clock() -> void:
	if live != null and live.state == "running" and not ClockControl.apply(live, hud_settings, vr != null):
		push_warning("live: the game didn't take the clock settings")
	_clock_ms = -1


## The real-time key: flips the flat screen's setting (saved) and the running game; VR stays in real time.
func _toggle_real_time() -> void:
	if vr != null:
		grab.flash("VR always runs in real time.")
		return
	hud_settings.real_time = not hud_settings.real_time
	var err := hud_settings.save_file()
	if err != OK:
		push_warning("real time not saved: %s" % error_string(err))
	key_menu.show_clock()
	_apply_clock()
	grab.flash(ClockControl.flip_note(hud_settings.real_time))


## Pauses real time or lets it go on (also after a hostile's auto-pause): the flat pause key and VR's menu row
## (lead-vr, vr.time_pause). Returns the note to show.
func toggle_time_pause() -> String:
	if live == null or live.state != "running":
		return "No game is running."
	eye_pause.forget()   # the pause (or going on) is the player's now
	_clock_ms = -1
	return ClockControl.toggle_pause(live)


## Real time paused (the pause key, or a hostile's auto-pause): the game takes no actions, so one sent now would wait
## and run the moment time goes on, toward whatever stopped it (lead-qa, 2026-11-20). The main loop's actions are
## dropped instead and a note says how to go on. True while paused.
func _held_by_pause() -> bool:
	if live == null or live.state != "running" or not ClockControl.paused(live.clock()):
		return false
	var t := Time.get_ticks_msec()
	if t - _pause_note_ms >= PAUSE_NOTE_MS:
		_pause_note_ms = t
		grab.flash(ClockControl.held_note())
	return true


## The HUD's time line, twice a second while a game runs.
func _clock_tick(now_ms: int) -> void:
	if _clock_ms >= 0 and now_ms - _clock_ms < 500:
		return
	_clock_ms = now_ms
	var running := live != null and live.state == "running"
	hud_data.set_clock(ClockControl.text(live.clock() if running else {}, running, vr != null))


func _menu_open() -> bool:
	return key_menu.visible or inspect.visible or character.visible or work_view.visible or map_view.visible \
			or request_ui.visible \
			or grab.tray_open() \
			or vise_bench.visible or main_menu != null


func _setup_back_out() -> void:
	back_out.add("keyboard", func() -> bool: return text_dock != null and text_dock.is_open(),
			func() -> bool:
				text_dock.close()
				return true)
	back_out.add("prompt", func() -> bool: return request_ui != null and request_ui.is_showing() and not request_ui.is_held(),
			func() -> bool: return request_ui.handle_input(BackOut.esc()))
	back_out.add("teleport pick", func() -> bool: return tele_pick.picking,
			func() -> bool:
				tele_pick.picking = false
				status = "teleport: cancelled"
				return true)
	back_out.add("map", func() -> bool: return map_view != null and map_view.visible,
			func() -> bool: return map_view.handle_key(BackOut.esc()))
	back_out.add("vehicle work", func() -> bool: return work_view != null and work_view.visible,
			func() -> bool: return work_view.handle_key(BackOut.esc()))
	back_out.add("character", func() -> bool: return character != null and character.visible,
			func() -> bool: return character.handle_key(BackOut.esc()))
	back_out.add("inventory", func() -> bool: return inspect != null and inspect.visible,
			func() -> bool: return inspect.handle_key(BackOut.esc()))
	back_out.add("tray", func() -> bool: return grab != null and grab.tray_open(),
			func() -> bool:
				grab.close_tray()
				return true)
	back_out.add("vise", func() -> bool: return vise_bench != null and vise_bench.clamped(),
			func() -> bool:
				vise_bench.release()
				return true)
	back_out.add("carry", func() -> bool: return vr == null and grab != null and grab.carrying(),
			func() -> bool: return grab.handle_event(BackOut.esc(), get_viewport().get_camera_3d(), _pointer()))
	back_out.add("wheel", func() -> bool: return request_ui != null and request_ui.wheel_waiting(),
			func() -> bool:
				request_ui.cancel_wheel()
				return true)
	back_out.add("ascii", func() -> bool: return classic != null and classic.visible,
			func() -> bool:
				classic.toggle()
				return true)
	back_out.add("look", _look_open,
			func() -> bool:
				_clear_look()
				return true)


## A look is showing (its panel text, the line to what was looked at, or the teleport marker).
func _look_open() -> bool:
	return (look_panel != null and not look_panel.text.is_empty()) or _look_line != null or _look_marker != null


## Esc / pad Start that nothing else took: backs out of one thing (back_out), or with nothing open opens the game
## menu (in a game or the viewer; the title menu keeps its own Esc). True when used.
func back_event(event: InputEvent) -> bool:
	if not BackOut.is_back(event) or main_menu != null or key_menu.visible:
		return false
	if back_out.step().is_empty():
		_open_key_menu()
	return true


func _open_key_menu() -> void:
	camera.set_process_unhandled_input(false)
	fp.set_process_unhandled_input(false)
	key_menu.open()


func _on_key_menu_closed() -> void:
	_apply_ui_scale()
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
	var typing := request_ui.wants_text_input() or key_menu.visible or inspect.visible \
			or grab.tray_open() or map_view.visible   # no camera or walking
	camera.set_process(vr == null and not first_person and not typing)
	if vr == null and view_mode == "top" and fp.z != _top_z:   # top-down: the cut follows the player's level
		_top_z = fp.z
		world.set_view_z_max(fp.z)
	fp.set_process(_fp_active() and not typing)
	if _fp_active() and live != null and not typing:
		_fp_live_step(false)
	compass.visible = vr == null
	busy_note.tick(Time.get_ticks_msec(), live != null and live.state == "running")   # VR draws it too (VrBusy)
	_eye_away_pause(Time.get_ticks_msec())
	_clock_tick(Time.get_ticks_msec())
	_eye_view_step(Time.get_ticks_msec())
	_update_aim()
	var cam := get_viewport().get_camera_3d()
	if cam != null and vr == null:   # no shaking in VR (comfort)
		var o := explosions.shake_offset()
		cam.h_offset = o.x
		cam.v_offset = o.y
	grab.update(get_viewport().get_camera_3d(), _pointer(), _fp_active() and not typing
			and request_ui.target_widget() == null, Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	grab.update_tray(get_viewport().get_camera_3d(), _pointer(), vr != null or key_menu.visible or inspect.visible
			or character.visible or work_view.visible or map_view.visible or request_ui.visible or main_menu != null)
	if typing or vr != null or (live != null and not _in_main_loop()):
		pour.cancel()   # a menu or prompt took the keys: its release won't come here
	elif pour.update(Time.get_ticks_msec()) == "refused":
		grab.flash("You can't pour that there.", true)
	creature_view.view_z_max = world.things_z_max()
	_carry_look()
	_hide_own_marks()
	_place_player_body()
	_update_look_line()
	var eyes := Compass.heading_of(_view().global_basis)
	if not is_nan(_stir_heading):   # a turn: held liquids lean against it (the player's, not a chase camera's)
		ItemTileView.stir(wrapf(eyes - _stir_heading, -180.0, 180.0) * ItemTileView.TURN_STIR)
	_stir_heading = eyes
	var drawn := drawn_view(get_viewport().get_camera_3d() if vr == null else null, _view())
	compass.heading_deg = Compass.heading_of(drawn.global_basis)
	if compass.visible:   # creatures the player perceives, by bearing from the camera on screen
		compass.set_level_blips(Compass.level_blips(world.snapshot, drawn.global_position,
				world.coords.ms_center_to_world))
	elif vr != null:   # the same blips on the VR wrist / belt compass (from the head)
		vr.compass.set_level_blips(Compass.level_blips(world.snapshot, _view().global_position,
				world.coords.ms_center_to_world))
	if vr != null:   # the VR Cheats page follows the F1 menu's gate (debug switch, --test / --cheats, test range)
		vr.cheats_allowed = key_menu != null and key_menu.cheats_allowed()
	var tile := world.coords.world_to_ms(_view().global_position)
	var view: String = {"first": "first person", "shoulder": "over the shoulder", "top": "top-down",
			"chase": "chase"}.get(view_mode,
			"outside, speed %.0f" % camera.speed)
	if live != null and live.state == "booting":   # the bridge's load phase, each frame (cheap)
		status = LiveSession.boot_text(live.boot_info())
	var info := "%s  camera square %s  %s  roofs %s  %d fps" % [view, tile, world.level_text(),
			"on" if world.roofs_visible else "off", Engine.get_frames_per_second()]
	var vr_line := "" if vr == null else "VR level %d  controllers %s  settings: left menu button  %s" % [
			vr.z, vr.current_layout(), vr_perf.last_line]
	var hands := "" if live == null else "in hands: " + _wielded_name()
	var on := hud_settings.key_help
	var texts := hud_texts(on, status, info, _help() if on else "", vr_line,
			_act_help() if on and live != null else "", hands)
	var now := Time.get_ticks_msec()
	if now - _hud_fit_ms >= HUD_FIT_MS or texts.size() != _hud_fit_n:   # measuring wraps the text: not every frame
		_hud_fit_ms = now
		_hud_fit_n = texts.size()
		_hud_pick = fit_index(hud, texts, hud_view.text_limit() - hud.position.y)
	# messages: hud_view's feed
	hud.text = texts[mini(_hud_pick, texts.size() - 1)]
	hud.visible = not key_menu.visible
	hud_view.visible = not key_menu.visible
	hud_view.avoid(Rect2(hud.global_position, hud.size) if hud.visible else Rect2())
	hints.offset_top = maxf(Hints.TOP, hud_view.marks_bottom() + 6.0)   # under the time line and the cheats
	_ride_step()


## The HUD's text along the top, longest first; main shows the longest that fits above the left column (which
## moves down under it, HudView.avoid): all the key help, then without CDDA's keys (`act`), then one short line
## (the only one with F1 > HUD > Key help off), then the status alone.
static func hud_texts(key_help: bool, status: String, info: String, help: String, vr_line: String, act: String,
		hands: String) -> PackedStringArray:
	var out := PackedStringArray()
	if key_help:
		if not act.is_empty():
			out.append(hud_lines([status, info, help, vr_line, act, hands]))
		out.append(hud_lines([status, info, help, vr_line, hands]))
	out.append(hud_lines([status, info, KEY_HELP_SHORT, vr_line, hands]))
	out.append(hud_lines([status, KEY_HELP_SHORT]))
	return out


## `parts` that aren't empty, one to a line.
static func hud_lines(parts: Array) -> String:
	var out := PackedStringArray()
	for p: String in parts:
		if not p.is_empty():
			out.append(p)
	return "\n".join(out)


## The first of `texts` whose height in `l` (its font and width, wrapped) is at most `max_h` px, else the last.
static func fit_index(l: Label, texts: PackedStringArray, max_h: float) -> int:
	var font := l.get_theme_font(&"font")
	var fs := l.get_theme_font_size(&"font_size")
	var fh := font.get_height(fs)
	if l.size.x <= 0.0 or fh <= 0.0:
		return 0
	var flags := TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	for i in texts.size():
		var h := font.get_multiline_string_size(texts[i], HORIZONTAL_ALIGNMENT_LEFT, l.size.x, fs, -1, flags).y
		var lines := ceili(h / fh - 0.01)
		if lines * (fh + l.get_theme_constant(&"line_spacing")) <= max_h:
			return i
	return texts.size() - 1


## The driving HUD, each frame: player.vehicle_state while the player is on a vehicle (flat screen; F1 > HUD >
## Driving gauge), kept off the hands panel, the look line, the HUD's text and its left column.
func _ride_step() -> void:
	var snap := world.snapshot
	var raw: Variant = snap.player_vehicle_state if snap != null and not snap.player_vehicle_state.is_empty() else null
	var face := NAN
	if raw is Dictionary:
		for veh: Snapshot.Vehicle in snap.vehicles:
			if veh.uid == snap.player_vehicle:
				face = veh.face_deg
				break
	var r := RideInfo.read(raw, _itype_name, face)
	vehicles_view.set_ride(r.uid if r.ok else 0, CarDash.reading_from(r))   # the 3D dash and wheel (C5 interiors)
	var fp_cam := vr == null and drawn_view(get_viewport().get_camera_3d(), _view()) == fp
	ride_hud.visible = vr == null and ride_shown(r, hud_settings, fp_cam) and hud_view.visible and not _menu_open()
	if not ride_hud.visible:
		hud_view.keep_feed_above(Rect2())
		return
	ride_hud.show_ride(r)
	var keep: Array[Rect2] = [hud.get_global_rect(), hud_view.column_rect(true)]
	for c: Control in [hands_panel, look_panel]:
		if c.visible:
			keep.append(c.get_global_rect())
	ride_hud.place(keep, hands_panel.get_global_rect() if hands_panel.visible else Rect2())
	hud_view.keep_feed_above(ride_hud.dash_rect())   # where no spot is free (small windows) the feed gives way


## An item type's name (its id when nameless), "" for an unknown index.
func _itype_name(type: int) -> String:
	var d: IdTables.Def = world.tables.def_at("itype", type) if world.tables != null else null
	if d == null:
		return ""
	return d.name if not d.name.is_empty() else d.id


## The key help when F1 > HUD > Key help is off, or there's no room for more.
const KEY_HELP_SHORT := "Esc back / menu  F1 keys, HUD, key help"


## The status and controls text along the top: as wide as the window, under the compass's hostile markers, wrapped
## so a small window shows all of it (the user, 2026-11-20).
static func hud_label() -> Label:
	var l := Label.new()
	l.name = "HudText"
	l.set_anchors_preset(Control.PRESET_TOP_WIDE)
	l.offset_left = 10
	l.offset_right = -12
	l.offset_top = 50
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	return l


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
	return out + "  Esc back / menu  F1 keys, HUD"


## Live game: the CDDA action keys and the hands, from the current bindings.
func _act_help() -> String:
	var parts := PackedStringArray()
	for a: StringName in InputActions.CDDA:
		parts.append("%s %s" % [InputActions.key_of(a), InputActions.info(a)[2]])
	parts.append("%s/%s hit left/right hand" % [InputActions.key_of(&"hand_off"), InputActions.key_of(&"hand_main")])
	parts.append("%s use / examine what you face  %s/%s hold / put away (off hand)" % [InputActions.key_of(&"use_held"),
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


func _input(event: InputEvent) -> void:
	InputActions.note_device(event)   # prompts name a pad's buttons after the pad was used
	if not BackOut.is_back(event):   # (Esc / Start while E's wheel is on its way: back_out's "wheel" step)
		request_ui.note_input(event)   # another key before E's menu came: that menu isn't E's wheel
	if key_menu.visible or inspect.visible or character.visible or work_view.visible or map_view.visible:
		tele_pick.picking = false   # a menu came up meanwhile (main's _input sees its clicks before its buttons do)
	var pick := tele_pick.pick_event(event)   # the cheat's "pick a square": this click is the square
	if pick == TeleportPick.PICK:
		_teleport((event as InputEventMouseButton).position)
		get_viewport().set_input_as_handled()
	elif pick == TeleportPick.CANCEL:
		status = "teleport: cancelled"
		get_viewport().set_input_as_handled()
	elif back_event(event):   # Esc / Start nothing above took: one thing backed out, or the game menu
		get_viewport().set_input_as_handled()


## The F1 cheats page's "Teleport: pick a square": the menu closes, the mouse is free, and the next left click on a
## square teleports there (Esc or a right click: cancel). False when teleporting isn't allowed (flat screen only).
func start_teleport_pick() -> bool:
	if vr != null or live == null or not live.can_teleport():
		return false
	key_menu.close()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	tele_pick.picking = true
	status = "teleport: click a square (Esc or right click: cancel)"
	return true


func _unhandled_input(event: InputEvent) -> void:
	if key_menu.visible or inspect.visible or character.visible or work_view.visible or map_view.visible:
		return   # the inspect view, the character screen and the work view take their keys themselves (their _input)
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.physical_keycode == InputActions.MENU_KEY:
		_open_key_menu()
		return
	if vr == null and grab.tray_event(event, get_viewport().get_camera_3d(), _pointer(), _can_inspect()):
		return   # L8: the tray opens on the bag or pile pointed at; while open it takes the clicks, Esc closes it
	if inspect.handle_key(event, _can_inspect()):
		return
	if character.handle_key(event, _can_open_character()):
		return
	if vr == null and map_view.handle_key(event, _can_open_character()):   # G5: M, the map
		return
	if vr != null and InputActions.pressed(event, &"map"):   # G5: VR's held map (lead-vr's VrRig)
		call_if(vr, "toggle_map", [])
		return
	if vr == null and InputActions.pressed(event, &"vehicle_work"):
		_open_work()
		return
	if InputActions.pressed(event, &"classic_view"):
		classic.toggle()
		return
	if InputActions.pressed(event, ClockControl.TOGGLE):
		_toggle_real_time()
		return
	if InputActions.pressed(event, ClockControl.PAUSE) and live != null and live.state == "running":
		grab.flash(toggle_time_pause())
		return
	if vr == null and aim.handle_event(event, get_viewport().get_camera_3d()):
		return
	if vr == null and live != null and _in_main_loop() and InputActions.pressed(event, &"use_held") \
			and _clamp_at_vise():
		return   # V2: E on a bench vise in reach with the gun wielded clamps it there (again: takes it back)
	if vr == null and live != null and _in_main_loop() and InputActions.pressed(event, &"use_held") \
			and _fit_held_mod():
		return   # F1: the gun wielded and a gunmod in the off hand: E fits it
	if vr == null and (live == null or _in_main_loop()) and pour.handle(event, Time.get_ticks_msec()):
		return   # E with a liquid in hand: waits for the release (a tap goes on below as usual) or a hold pours
	if vr == null and (live == null or _in_main_loop()) and grab.take_hovered(event):
		return   # E on an item you look at takes it (else E uses / examines, below)
	if vr == null and (live == null or _in_main_loop()) and InputActions.pressed(event, &"use_held") \
			and _open_cargo():
		return   # car storage: E on a trunk, glovebox or other cargo space next to you opens it and lays it out
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
		if tele_pick.marked is Vector3i:   # a look is open: its marker
			_teleport_to(tele_pick.marked)
		else:
			_teleport(get_viewport().get_mouse_position())
		return
	if live != null and _live_action(event):
		return
	if InputActions.pressed(event, &"cutaway_up"):   # (Esc: back_event, in _input)
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
