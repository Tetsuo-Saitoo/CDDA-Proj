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
	var v: Variant = cfg.get_value("compass", "opacity", DEFAULT_COMPASS_OPACITY)
	if v is float or v is int:
		compass_opacity = clamp_opacity(float(v))
		return ""
	return "%s: compass opacity is not a number" % path


func save_file(path := FILE) -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value("compass", "opacity", snappedf(compass_opacity, 0.01))
	return cfg.save(path)
