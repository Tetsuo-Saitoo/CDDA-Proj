extends Node3D
## M1 "ghost walk" viewer: loads a snapshot (default: the mock town), meshes it, and lets you fly around.
## Keys: PageUp/PageDown show levels up to z (cutaway), R roofs, F5 reload the snapshot, Home back to
## the player. Command line, after `--`: --snapshot=<path> --view-z=<z> --no-roofs
## --camera=<x>,<y>,<z>,<yaw_deg>,<pitch_deg> (Godot metres) --screenshot=<png> (save one frame, quit).

const HELP := "RMB look  WASD move  E/Q up/down  Shift fast  wheel speed  PgUp/PgDn level  R roofs  F5 reload  Home player"

var world: WorldView
var camera: FlyCamera
var sun: DirectionalLight3D
var hud: Label
var snapshot_path := ""
var status := ""
var _args := {}


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
	var n := world.apply_snapshot(snap)
	status = "turn %d seq %d: load %d ms, rebuilt %d of %d submaps in %d ms, %d k vertices" % [
			snap.turn, snap.seq, t1 - t0, n, snap.submaps.size(), Time.get_ticks_msec() - t1,
			world.vertex_count / 1000]
	print(status)
	_aim_sun(snap.sun_alt_deg, snap.sun_az_deg)


func _frame_player() -> void:
	if world.snapshot == null:
		return
	var target := world.coords.ms_center_to_world(world.snapshot.player_pos)
	camera.look_from(target + Vector3(-20, 28, 30), target)


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


func _process(_delta: float) -> void:
	var tile := world.coords.world_to_ms(camera.position)
	hud.text = "%s\ncamera square %s  view z <= %d  roofs %s  speed %.0f  %d fps\n%s" % [
			status, tile, world.view_z_max, "on" if world.roofs_visible else "off", camera.speed,
			Engine.get_frames_per_second(), HELP]


func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.physical_keycode:
		KEY_PAGEUP:
			world.set_view_z_max(world.view_z_max + 1)
		KEY_PAGEDOWN:
			world.set_view_z_max(world.view_z_max - 1)
		KEY_R:
			world.set_roofs_visible(not world.roofs_visible)
		KEY_F5:
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
