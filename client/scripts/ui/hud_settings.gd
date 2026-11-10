class_name HudSettings
extends RefCounted
## Flat-screen HUD settings, picked in the F1 menu (KeyMenu) and saved in user://hud.cfg (ConfigFile).
## The file is treated as hostile: size-capped, no object constructors, wrong types and NaN ignored, values
## clamped. A missing or bad file leaves the defaults.

const FILE := "user://hud.cfg"
const MAX_FILE_BYTES := 16 << 10
const DEFAULT_COMPASS_OPACITY := 0.85
const MIN_COMPASS_OPACITY := 0.0   # 0 hides the compass; the F1 slider brings it back

var compass_opacity := DEFAULT_COMPASS_OPACITY
## The F1 menu's Cheats page (testing). Off unless turned on; only a real bool in the file turns it on.
var debug_cheats := false
## C9: the flat-screen view V last picked (main.gd): first person, over the shoulder, top-down, or the outside
## fly camera.
const VIEWS := FirstPersonCamera.VIEWS
var view := "first"


static func clamp_opacity(v: float) -> float:
	return clampf(v, MIN_COMPASS_OPACITY, 1.0) if is_finite(v) else DEFAULT_COMPASS_OPACITY


## Reads the file; returns "" or why it was ignored (missing is not an error).
func load_file(path := FILE) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "cannot open %s" % path
	if f.get_length() > MAX_FILE_BYTES:
		return "%s is over %d bytes" % [path, MAX_FILE_BYTES]
	var text := f.get_as_text()
	# Godot's variant parser builds objects from "Object(...)" and loads resources: never from a file.
	for bad: String in ["Object(", "Resource(", "ExtResource(", "SubResource("]:
		if bad in text:
			return "%s has %s, ignored" % [path, bad]
	var cfg := ConfigFile.new()
	if cfg.parse(text) != OK:
		return "%s doesn't parse" % path
	var d: Variant = cfg.get_value("debug", "cheats", false)
	debug_cheats = d if d is bool else false
	var vw: Variant = cfg.get_value("view", "mode", "first")
	view = vw if vw is String and vw in VIEWS else "first"
	var v: Variant = cfg.get_value("compass", "opacity", DEFAULT_COMPASS_OPACITY)
	if v is float or v is int:
		compass_opacity = clamp_opacity(float(v))
		return "" if d is bool else "%s: debug cheats is not true or false" % path
	return "%s: compass opacity is not a number" % path


func save_file(path := FILE) -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value("compass", "opacity", snappedf(compass_opacity, 0.01))
	cfg.set_value("debug", "cheats", debug_cheats)
	cfg.set_value("view", "mode", view if view in VIEWS else "first")
	return cfg.save(path)
