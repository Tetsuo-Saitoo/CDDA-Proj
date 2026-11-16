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
## The mood's screen tint (MoodCue). On unless turned off; anything but a real bool in the file leaves it on.
var mood_cues := true
## F3: the hurt tint at the view's edges (HurtCue). On unless turned off, like the mood tint. Saved as [hurt] cues.
var hurt_cues := true
## Bright flashes: lightning (WeatherView.flash_enabled) and the first-person muzzle flash (the viewmodel's
## `flashes`). On unless turned off, like the mood tint. Saved as [weather] flash (its first use).
var weather_flash := true
## C9: the flat-screen view V last picked (main.gd): first person, over the shoulder, top-down, or the outside
## fly camera.
const VIEWS := FirstPersonCamera.VIEWS
var view := "first"
## G1: the message feed's filter groups (HudData.message_group), in the F1 menu's order, with their labels.
const FEED_GROUPS := {"good": "Good news", "bad": "Bad news", "warning": "Warnings", "info": "Info", "other": "Other"}
## The groups left out of the feed (HudData.set_feed_hidden). None unless turned off; saved as [feed] hide, a list
## of group names (anything but known names ignored).
var feed_hidden := PackedStringArray()
## G7 options (flat screen; the headset has its own, VrSettings): the mouse look speed (times the cameras' own),
## inverted up-down look, the field of view in degrees, the 3D render scale, fullscreen, vsync and the size of the
## menus and HUD (the window's content scale). Saved as [look] speed, invert, fov and [display] scale, fullscreen,
## vsync, ui_scale; numbers out of range are clamped, anything else leaves the default.
const LOOK_SPEEDS := Vector2(0.25, 4.0)
const FOVS := Vector2(60.0, 110.0)
const RENDER_SCALES := Vector2(0.5, 1.0)
const UI_SCALES := Vector2(0.75, 2.0)
const DEFAULT_FOV := 75.0   # Camera3D's own
var look_speed := 1.0
var invert_y := false
var fov := DEFAULT_FOV
var render_scale := 1.0
var fullscreen := false
var vsync := true
var ui_scale := 1.0
## lead-world's weather detail (WeatherView.quality: MINIMAL, LOW, HIGH), flat screen and headset alike. Saved as
## [weather] quality; anything but a whole number leaves HIGH, a number out of range is clamped.
var weather_quality := WeatherView.HIGH


static func clamp_opacity(v: float) -> float:
	return clampf(v, MIN_COMPASS_OPACITY, 1.0) if is_finite(v) else DEFAULT_COMPASS_OPACITY


## `v` as a number within `limits` (x..y), or `fallback` when it isn't a finite number.
static func clamp_to(v: Variant, limits: Vector2, fallback: float) -> float:
	if not (v is float or v is int) or not is_finite(float(v)):
		return fallback
	return clampf(float(v), limits.x, limits.y)


## The known FEED_GROUPS names in `v` (an Array or PackedStringArray), each once, in FEED_GROUPS order; anything
## else gives none.
static func feed_groups_from(v: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if not (v is Array or v is PackedStringArray):
		return out
	var given: Array = Array(v).slice(0, 64)
	for g: String in FEED_GROUPS:
		if given.has(g):
			out.append(g)
	return out


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
	var mc: Variant = cfg.get_value("mood", "cues", true)
	mood_cues = mc if mc is bool else true
	var hc: Variant = cfg.get_value("hurt", "cues", true)
	hurt_cues = hc if hc is bool else true
	var wf: Variant = cfg.get_value("weather", "flash", true)
	weather_flash = wf if wf is bool else true
	var vw: Variant = cfg.get_value("view", "mode", "first")
	view = vw if vw is String and vw in VIEWS else "first"
	feed_hidden = feed_groups_from(cfg.get_value("feed", "hide", []))
	look_speed = clamp_to(cfg.get_value("look", "speed", 1.0), LOOK_SPEEDS, 1.0)
	var iy: Variant = cfg.get_value("look", "invert", false)
	invert_y = iy if iy is bool else false
	fov = clamp_to(cfg.get_value("look", "fov", DEFAULT_FOV), FOVS, DEFAULT_FOV)
	render_scale = clamp_to(cfg.get_value("display", "scale", 1.0), RENDER_SCALES, 1.0)
	var fs: Variant = cfg.get_value("display", "fullscreen", false)
	fullscreen = fs if fs is bool else false
	var vs: Variant = cfg.get_value("display", "vsync", true)
	vsync = vs if vs is bool else true
	ui_scale = clamp_to(cfg.get_value("display", "ui_scale", 1.0), UI_SCALES, 1.0)
	var wq: Variant = cfg.get_value("weather", "quality", WeatherView.HIGH)
	weather_quality = clampi(wq, WeatherView.MINIMAL, WeatherView.HIGH) if wq is int else WeatherView.HIGH
	var v: Variant = cfg.get_value("compass", "opacity", DEFAULT_COMPASS_OPACITY)
	if v is float or v is int:
		compass_opacity = clamp_opacity(float(v))
		if not (d is bool):
			return "%s: debug cheats is not true or false" % path
		return "" if hc is bool else "%s: hurt tint is not true or false" % path
	return "%s: compass opacity is not a number" % path


func save_file(path := FILE) -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value("compass", "opacity", snappedf(compass_opacity, 0.01))
	cfg.set_value("debug", "cheats", debug_cheats)
	cfg.set_value("mood", "cues", mood_cues)
	cfg.set_value("hurt", "cues", hurt_cues)
	cfg.set_value("weather", "flash", weather_flash)
	cfg.set_value("view", "mode", view if view in VIEWS else "first")
	cfg.set_value("feed", "hide", Array(feed_groups_from(feed_hidden)))
	cfg.set_value("look", "speed", snappedf(clamp_to(look_speed, LOOK_SPEEDS, 1.0), 0.01))
	cfg.set_value("look", "invert", invert_y)
	cfg.set_value("look", "fov", roundf(clamp_to(fov, FOVS, DEFAULT_FOV)))
	cfg.set_value("display", "scale", snappedf(clamp_to(render_scale, RENDER_SCALES, 1.0), 0.01))
	cfg.set_value("display", "fullscreen", fullscreen)
	cfg.set_value("display", "vsync", vsync)
	cfg.set_value("display", "ui_scale", snappedf(clamp_to(ui_scale, UI_SCALES, 1.0), 0.01))
	cfg.set_value("weather", "quality", clampi(weather_quality, WeatherView.MINIMAL, WeatherView.HIGH))
	return cfg.save(path)
