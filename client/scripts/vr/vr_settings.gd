class_name VrSettings
extends RefCounted
## VR comfort and controller settings (block L1/L5): defaults, the in-headset menu's choices, the command line
## and `user://vr.json`. The menu (VrMenu, left menu button) saves the file; the command line wins over it.
## The file is treated as hostile: size-capped, unknown keys and bad values dropped.

const FILE := "user://vr.json"
const MAX_FILE_BYTES := 4096
const DEFAULTS := {"move": "smooth", "move_dir": "head", "turn": "snap", "snap_deg": 45.0, "turn_speed": 120.0,
		"speed": 2.0, "vignette": 0.6, "blink": true, "layout": "auto", "hands": "auto", "swap_sticks": false}
## Key -> allowed words, or [min, max, menu step] for numbers. Bools are on/off.
const SPEC := {
	"move": ["smooth", "teleport"], "move_dir": ["head", "hand"], "turn": ["snap", "smooth", "off"],
	"layout": ["auto", "quest", "vive"], "hands": ["auto", "buttons", "boxes"],
	"snap_deg": [15.0, 90.0, 15.0], "turn_speed": [30.0, 360.0, 30.0], "speed": [0.5, 5.0, 0.5],
	"vignette": [0.0, 1.0, 0.2], "blink": [], "swap_sticks": [],
}
## Command-line option (after `--`) -> key.
const ARGS := {"vr-move": "move", "vr-move-dir": "move_dir", "vr-turn": "turn", "vr-snap": "snap_deg",
		"vr-turn-speed": "turn_speed", "vr-speed": "speed", "vr-vignette": "vignette", "vr-blink": "blink",
		"vr-layout": "layout", "vr-hands": "hands", "vr-swap-sticks": "swap_sticks"}
## Menu rows: key, label.
const ROWS := [["move", "Move"], ["move_dir", "Move toward"], ["speed", "Move speed"], ["turn", "Turn"],
		["snap_deg", "Snap angle"], ["turn_speed", "Smooth turn speed"], ["vignette", "Vignette"],
		["blink", "Blink on jumps"], ["swap_sticks", "Move with right stick"], ["layout", "Controllers"],
		["hands", "Hands"]]


## `value` checked against SPEC: the cleaned value, or null when it isn't allowed. Strings from the command
## line ("on", "0.5") and JSON values (true, 0.5) both work.
static func clean(key: String, value: Variant) -> Variant:
	if not SPEC.has(key):
		return null
	var spec: Array = SPEC[key]
	if spec.is_empty():   # bool
		if value is bool:
			return value
		if value is String and value in ["on", "off", "true", "false", "1", "0"]:
			return value in ["on", "true", "1"]
		return null
	if spec[0] is String:
		return value if value is String and value in spec else null
	var f := NAN
	if value is float or value is int:
		f = float(value)
	elif value is String and value.is_valid_float():
		f = value.to_float()
	if not is_finite(f):
		return null
	return clampf(f, spec[0], spec[1])


## Settings from the command line on top of `base` (the file's or the defaults). Bad values keep the base.
static func from_args(args: Dictionary, base := DEFAULTS) -> Dictionary:
	var s := base.duplicate()
	for arg: String in ARGS:
		if args.has(arg):
			var v: Variant = clean(ARGS[arg], args[arg])
			if v != null:
				s[ARGS[arg]] = v
			else:
				push_warning("--%s=%s ignored" % [arg, args[arg]])
	return s


## The saved settings over the defaults; anything missing, unknown or bad is left at its default.
static func load_file(path := FILE) -> Dictionary:
	var s := DEFAULTS.duplicate()
	if not FileAccess.file_exists(path):
		return s
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() > MAX_FILE_BYTES:
		push_warning("VR settings: %s unreadable or too big, using defaults" % path)
		return s
	var data: Variant = JSON.parse_string(f.get_as_text())
	if not data is Dictionary:
		push_warning("VR settings: %s isn't a JSON object, using defaults" % path)
		return s
	for key: String in DEFAULTS:
		var v: Variant = clean(key, data.get(key)) if data.has(key) else null
		if v != null:
			s[key] = v
	return s


static func save_file(s: Dictionary, path := FILE) -> bool:
	var out := {}
	for key: String in DEFAULTS:
		var v: Variant = clean(key, s.get(key))
		out[key] = v if v != null else DEFAULTS[key]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(out, "  "))
	return true


## The next allowed value of `key` (dir +1 / -1), wrapping for words and bools, stopping at the ends for numbers.
static func step(s: Dictionary, key: String, dir: int) -> Variant:
	var spec: Array = SPEC[key]
	var v: Variant = s.get(key, DEFAULTS[key])
	if spec.is_empty():
		return not v
	if spec[0] is String:
		return spec[wrapi(spec.find(v) + dir, 0, spec.size())]
	return clampf(snappedf(float(v) + dir * spec[2], spec[2]), spec[0], spec[1])


static func label(key: String, v: Variant) -> String:
	if v is bool:
		return "on" if v else "off"
	match key:
		"vignette":
			return "off" if v <= 0.0 else "%d %%" % roundi(v * 100.0)
		"snap_deg":
			return "%d deg" % roundi(v)
		"turn_speed":
			return "%d deg/s" % roundi(v)
		"speed":
			return "%.1f m/s" % v
		"layout":
			return {"auto": "auto (from the runtime)", "quest": "sticks + A/B/X/Y (Quest, Index, Pico)",
					"vive": "trackpads (Vive wands, WMR)"}[v]
		"hands":
			return {"auto": "finger tracking, else from buttons", "buttons": "fingers from buttons", "boxes": "simple boxes"}[v]
	return str(v)
