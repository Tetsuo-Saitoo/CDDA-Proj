extends SceneTree
## Render check: draws the mock town on the real renderer in several weathers and saves each view as a PNG, so a
## shader that doesn't compile or a look that is plainly wrong shows before a player sees it. Headless can't do
## this, so it is not part of run_tests.gd: it opens a small window, takes its pictures and closes itself (~40 s).
## From the repo root:
##   godot --path client --resolution 960x540 --quit-after 6000 --script res://tests/render_check.gd -- --out=<folder>
## (--quit-after is only a safety net; --out defaults to user://render_check; --only=<text> takes just the views
## whose name has that text). Exit code 0 = every picture saved and no error logged (shader errors included);
## then look at the pictures. Add a view to SHOTS to check more.

const Main := preload("res://scripts/main.gd")
const ErrorCatch := preload("res://tests/error_catch.gd")

# CDDA's weather values: env fields over the mock's own.
const CLEAR := {"precip": 0, "precip_kind": 0, "sight_penalty": 1.0, "light_modifier": 0, "sun_multiplier": 1.0}
const CLOUDY := {"precip": 0, "precip_kind": 0, "sight_penalty": 1.0, "light_modifier": -20, "sun_multiplier": 0.3}
const FOG := {"precip": 0, "precip_kind": 0, "sight_penalty": 1.7, "light_modifier": -40, "sun_multiplier": 0.3}
const RAIN := {"precip": 3, "precip_kind": 1, "sight_penalty": 1.1, "light_modifier": -30, "sun_multiplier": 0.03,
		"wind_speed": 6.0, "wind_dir_deg": 270.0}
const SNOW := {"precip": 3, "precip_kind": 2, "sight_penalty": 1.3, "light_modifier": -20, "sun_multiplier": 0.15,
		"wind_speed": 2.0, "wind_dir_deg": 270.0}
const STORM := {"precip": 3, "precip_kind": 1, "sight_penalty": 1.25, "light_modifier": -45, "sun_multiplier": 0.01,
		"weather_sound": 4, "wind_speed": 8.0, "wind_dir_deg": 270.0}

## name, env, and optionally: view (first / shoulder / top / outside), yaw and pitch in degrees (first person:
## 0 looks north, 90 west), night, move (squares from the mock's player), roof (the player counts as sheltered),
## settle (seconds before the picture), flash (a lightning event, pictured at once and again after it), lamp (a
## light source on the player's square: CDDA's light falls off around it).
const SHOTS := [
	{"name": "clear", "env": CLEAR, "yaw": 45.0},
	{"name": "cloudy", "env": CLOUDY, "yaw": 45.0},
	{"name": "fog", "env": FOG, "yaw": 45.0},
	{"name": "fog_hands_down", "env": FOG, "yaw": 45.0, "pitch": -50.0},
	{"name": "rain_wind", "env": RAIN, "yaw": 45.0},
	{"name": "rain_wind_south", "env": RAIN, "yaw": 180.0},
	{"name": "snow", "env": SNOW, "yaw": 45.0, "settle": 5.0},
	{"name": "storm_night", "env": STORM, "yaw": 45.0, "night": true, "flash": true},
	{"name": "clear_under_roof", "env": CLEAR, "yaw": -90.0, "pitch": 20.0, "move": Vector3i(-8, -6, 0), "roof": true},
	{"name": "rain_under_roof", "env": RAIN, "yaw": -90.0, "move": Vector3i(-8, -6, 0), "roof": true},
	{"name": "rain_under_roof_up", "env": RAIN, "yaw": -90.0, "pitch": 40.0, "move": Vector3i(-8, -6, 0), "roof": true},
	{"name": "rain_shoulder", "env": RAIN, "view": "shoulder", "yaw": 45.0},
	{"name": "rain_top", "env": RAIN, "view": "top"},
	{"name": "fog_top", "env": FOG, "view": "top"},
	{"name": "clear_again", "env": CLEAR, "yaw": 45.0},
	# Inside the building: the ceiling and the walls must read as a room, by day and by lamp light.
	{"name": "room_day_window", "env": CLEAR, "yaw": -90.0, "pitch": 35.0, "move": Vector3i(-8, -6, 0), "roof": true},
	{"name": "room_day_inward", "env": CLEAR, "yaw": 90.0, "pitch": 25.0, "move": Vector3i(-8, -6, 0), "roof": true},
	{"name": "room_day_up", "env": CLEAR, "yaw": 90.0, "pitch": 80.0, "move": Vector3i(-8, -6, 0), "roof": true},
	{"name": "room_night_lamp", "env": CLEAR, "yaw": 90.0, "pitch": 25.0, "move": Vector3i(-8, -6, 0), "roof": true,
			"night": true, "lamp": true},
	{"name": "room_night_dark", "env": CLEAR, "yaw": 90.0, "pitch": 25.0, "move": Vector3i(-8, -6, 0), "roof": true,
			"night": true},
]

var _main: Main
var _data: Dictionary
var _out := "user://render_check"
var _saved := 0
var _failed := 0
var _only := ""


func _initialize() -> void:
	_run()


func _run() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
		if a.begins_with("--only="):
			_only = a.trim_prefix("--only=")
	if DisplayServer.get_name() == "headless":
		print("render check: needs a window and a GPU (run it without --headless)")
		quit(2)
		return
	var catch := ErrorCatch.new()
	OS.add_logger(catch)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out))
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	root.add_child(_main)
	await _seconds(1.0)
	_main.weather.blend_s = 0.0
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_main.snapshot_path))
	if not parsed is Dictionary or _main.world.snapshot == null:
		print("render check: the mock snapshot didn't load (%s)" % _main.snapshot_path)
		quit(1)
		return
	_data = parsed
	for i in SHOTS.size():
		if _only.is_empty() or String(SHOTS[i]["name"]).contains(_only):
			await _shot(i, SHOTS[i])
	var errors := catch.take()
	OS.remove_logger(catch)
	for e in errors:
		print("render check: logged %s" % e)
	print("render check: %d pictures in %s, %d not saved, %d errors logged" %
			[_saved, ProjectSettings.globalize_path(_out), _failed, errors.size()])
	_main.queue_free()
	await process_frame
	quit(0 if _failed == 0 and errors.is_empty() else 1)


func _seconds(s: float) -> void:
	await create_timer(s).timeout


func _shot(index: int, shot: Dictionary) -> void:
	var d := _data.duplicate(false)
	var env: Dictionary = (_data["env"] as Dictionary).duplicate()
	env.merge(shot["env"], true)
	env["sheltered"] = bool(shot.get("roof", false))
	if shot.get("night", false):
		env["ambient_light"] = 2
		env["sun_alt_deg"] = -30.0
		var dark := []
		dark.resize(144)
		dark.fill(2)
		var submaps := []
		for s: Dictionary in _data["submaps"]:
			var copy := s.duplicate(false)
			copy["light"] = dark
			submaps.append(copy)
		d["submaps"] = submaps
	else:
		d["submaps"] = (_data["submaps"] as Array).duplicate(false)
	d["env"] = env
	var player: Dictionary = (_data["player"] as Dictionary).duplicate(true)
	var move: Vector3i = shot.get("move", Vector3i.ZERO)
	player["pos"] = [int(player["pos"][0]) + move.x, int(player["pos"][1]) + move.y, int(player["pos"][2]) + move.z]
	d["player"] = player
	if shot.get("lamp", false):
		_lamp(d, Vector3i(player["pos"][0], player["pos"][1], player["pos"][2]))
	var snap := Snapshot.from_data(d)
	if not snap.is_valid():
		print("render check: %s: snapshot rejected: %s" % [shot["name"], snap.error])
		_failed += 1
		return
	_main._show(snap)
	_main._set_view(shot.get("view", "first"))
	_main._frame_player()
	_main.fp.set_look(deg_to_rad(shot.get("yaw", 0.0)), deg_to_rad(shot.get("pitch", 0.0)))
	await _seconds(shot.get("settle", 1.5))
	if shot.get("flash", false):
		await _save(index, shot["name"] + "_before")
		_main.weather.on_events([{"kind": "lightning"}])
		await process_frame
		await _save(index, shot["name"] + "_flash")
		await _seconds(1.0)
		await _save(index, shot["name"] + "_after")
	else:
		await _save(index, shot["name"])


## A light source on square `at`: 60 there, 8 less per square away (CDDA light levels), on that level.
func _lamp(d: Dictionary, at: Vector3i) -> void:
	var submaps: Array = d["submaps"]
	for i in submaps.size():
		var s: Dictionary = submaps[i]
		var o := Vector3i(int(s["pos"][0]) * 12, int(s["pos"][1]) * 12, int(s["pos"][2]))
		if o.z != at.z or absi(o.x + 6 - at.x) > 14 or absi(o.y + 6 - at.y) > 14:
			continue
		var copy := s.duplicate(false)
		var light: Array = (s["light"] as Array).duplicate()
		for t in 144:
			var dist := Vector2(o.x + t % 12 - at.x, o.y + t / 12 - at.y).length()
			light[t] = maxi(int(light[t]), roundi(60.0 - 8.0 * dist))
		copy["light"] = light
		submaps[i] = copy


func _save(index: int, name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var path := "%s/%02d_%s.png" % [_out, index, name]
	var err := img.save_png(path) if img != null else ERR_CANT_ACQUIRE_RESOURCE
	if err == OK:
		_saved += 1
	else:
		_failed += 1
		print("render check: %s not saved: %s" % [path, error_string(err)])
