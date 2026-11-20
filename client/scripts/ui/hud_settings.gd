class_name HudSettings
extends RefCounted
## Flat-screen HUD settings, picked in the F1 menu (KeyMenu) and saved in user://hud.cfg (ConfigFile).
func left_handed() -> bool:
	return main_hand == "left"


## The CDDA hand ("main" / "off") the key for hand `side` ("left" / "right") strikes with.
static func hand_for(side: String, left_hand_main: bool) -> String:
	return "main" if (side == "left") == left_hand_main else "off"


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
## The flat-screen main hand (the headset has its own, VrSettings `main_hand`): "right", or "left" for a left-hander.
## Keys 1 / 2 strike with the left / right hand, so a left-hander's 1 is the main hand (hand_for); the gun rests on
## the left (WeaponViewmodel.left_handed) and the hands panel shows the main hand on the left. CDDA's main hand is
## the wielding one either way. Saved as [hands] main; anything but MAIN_HANDS is ignored (the file: "right").
const MAIN_HANDS: Array[String] = ["right", "left"]
var main_hand := "right":
	set(v):
		if v is String and v in MAIN_HANDS:
			main_hand = v
var fov := DEFAULT_FOV
var render_scale := 1.0
var fullscreen := false
var vsync := true
var ui_scale := 1.0
## lead-world's weather detail (WeatherView.quality: MINIMAL, LOW, HIGH), flat screen and headset alike. Saved as
## [weather] quality; anything but a whole number leaves HIGH, a number out of range is clamped.
var weather_quality := WeatherView.HIGH
## How E shows an object's menu (radial menus, user 2026-11-16): MENU_HOLD a wheel, releasing E picks; MENU_CLICK a
## wheel that stays until a click; MENU_LIST CDDA's list. Saved as [controls] context_menu; anything but a whole
## number leaves MENU_HOLD, a number out of range is clamped.
enum { MENU_HOLD, MENU_CLICK, MENU_LIST }
const MENU_NAMES := ["E: wheel (hold)", "E: wheel (click)", "E: list"]
var context_menu := MENU_HOLD
## G7: the game's loudness, 0 (silent) .. 1 (as made), on the Master bus where every sound plays. Saved as [sound]
## volume, clamped like the other numbers.
const VOLUMES := Vector2(0.0, 1.0)
var volume := 1.0
## G7: the background sound's loudness (lead-world's weather: rain, roof, wind, thunder) on its own bus, AMBIENCE_BUS,
## which sends to Master (so the volume above still covers it). Saved as [sound] ambience.
const AMBIENCE_BUS := &"Ambience"
var ambience_volume := 1.0
## Eye tracking (user, 2026-11-19): one switch per idea, the flat screen and VR alike (the F1 menu's "Eye tracking"
## row; the VR menu shows the same). "tracker" is the master switch: off, no feature uses the gaze. A switch only
## allows a feature: each needs a tracked gaze (GazeSource) but those in GAZE_FREE, so without a tracker the game is as
## before whatever the switches say. id -> [label, default, tooltip], in the user's order; owners in TASKS.md. Saved
## as [eyes] <id>; anything but a real bool, or an unknown id, leaves the default.
const EYE_FEATURES := {
	"tracker": ["Use the eye tracker", false, "Lets the features on the right use where you look. Off: none do. VR: takes effect after restarting VR."],
	"zoom": ["Zoom where you look", true, "Holding the zoom key narrows the view toward the spot you look at."],
	"edge_turn": ["See past the edge", true, "Looking at a screen edge turns the view a little that way (flat screen)."],
	"labels": ["Name what you look at", true, "A short label over what you look at for a moment."],
	"light_adapt": ["Eyes adjust to light", false, "Bright and dark places take a moment to see in, like real eyes."],
	"throw_look": ["Throw where you look", true,
			"A throw goes to the square you look at; the trigger or throw key throws. Gun aim stays on the sights."],
	"menus": ["Point at menus by eye", true, "What you look at in a menu is pointed at; a key still clicks it."],
	"away_pause": ["Pause when you look away", true, "Real-time play pauses while you look away from the screen."],
	"unease": ["Unease at the edges", false, "Things move at the edge of your sight now and then. Atmosphere only."],
	"lean": ["Lean to peek", true, "Lean keys tilt the view and peek around a corner. Needs no eye tracker."],
}
const GAZE_FREE := ["lean"]   # features that work without a tracker (and without the master switch)
var eyes := {}                # id -> bool, the switches set; a missing one is its default
var eyes_from_file := false   # the file had an [eyes] section (lead-vr: VrSettings' old `eyes` moves here once)


## Feature `id` (EYE_FEATURES) may run: its switch on and, unless GAZE_FREE, the master switch too. Whether a gaze is
## tracked is the feature's own check (GazeSource). False for an unknown id.
func eye_on(id: String) -> bool:
	if not EYE_FEATURES.has(id):
		return false
	if id != "tracker" and not id in GAZE_FREE and not eye_switch("tracker"):
		return false
	return eye_switch(id)


## Switch `id` as set (its default when never set); false for an unknown id.
func eye_switch(id: String) -> bool:
	if not EYE_FEATURES.has(id):
		return false
	var v: Variant = eyes.get(id)
	return v if v is bool else bool(EYE_FEATURES[id][1])


## Sets switch `id`; false for an unknown id (nothing set).
func set_eye(id: String, on: bool) -> bool:
	if not EYE_FEATURES.has(id):
		return false
	eyes[id] = on
	return true


## The index of the AMBIENCE_BUS, added (sending to Master) when it isn't there yet. main calls it first thing, so
## the players that look for the bus when they are made find it.
static func ensure_ambience_bus() -> int:
	var i := AudioServer.get_bus_index(AMBIENCE_BUS)
	if i >= 0:
		return i
	AudioServer.add_bus()
	i = AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, AMBIENCE_BUS)
	AudioServer.set_bus_send(i, &"Master")
	return i


## Sets bus `i` to linear loudness `v` (0..1): muted at 0, else in dB.
static func set_bus_loudness(i: int, v: float) -> void:
	if i < 0 or i >= AudioServer.bus_count:
		return
	var vol := clamp_to(v, VOLUMES, 1.0)
	AudioServer.set_bus_mute(i, vol <= 0.0)
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(vol, 0.001)))


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
	path = UserFiles.at(path)   # a test run's own folder
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
	var mh: Variant = cfg.get_value("hands", "main", "right")
	main_hand = mh if mh is String and mh in MAIN_HANDS else "right"
	fov = clamp_to(cfg.get_value("look", "fov", DEFAULT_FOV), FOVS, DEFAULT_FOV)
	render_scale = clamp_to(cfg.get_value("display", "scale", 1.0), RENDER_SCALES, 1.0)
	var fs: Variant = cfg.get_value("display", "fullscreen", false)
	fullscreen = fs if fs is bool else false
	var vs: Variant = cfg.get_value("display", "vsync", true)
	vsync = vs if vs is bool else true
	ui_scale = clamp_to(cfg.get_value("display", "ui_scale", 1.0), UI_SCALES, 1.0)
	var wq: Variant = cfg.get_value("weather", "quality", WeatherView.HIGH)
	weather_quality = clampi(wq, WeatherView.MINIMAL, WeatherView.HIGH) if wq is int else WeatherView.HIGH
	var cm: Variant = cfg.get_value("controls", "context_menu", MENU_HOLD)
	context_menu = clampi(cm, MENU_HOLD, MENU_LIST) if cm is int else MENU_HOLD
	volume = clamp_to(cfg.get_value("sound", "volume", 1.0), VOLUMES, 1.0)
	ambience_volume = clamp_to(cfg.get_value("sound", "ambience", 1.0), VOLUMES, 1.0)
	eyes.clear()
	eyes_from_file = cfg.has_section("eyes")
	for id: String in EYE_FEATURES:
		var e: Variant = cfg.get_value("eyes", id) if cfg.has_section_key("eyes", id) else null
		if e is bool:
			eyes[id] = e
	var v: Variant = cfg.get_value("compass", "opacity", DEFAULT_COMPASS_OPACITY)
	if v is float or v is int:
		compass_opacity = clamp_opacity(float(v))
		if not (d is bool):
			return "%s: debug cheats is not true or false" % path
		return "" if hc is bool else "%s: hurt tint is not true or false" % path
	return "%s: compass opacity is not a number" % path


func save_file(path := FILE) -> Error:
	path = UserFiles.at(path)
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
	cfg.set_value("hands", "main", main_hand if main_hand in MAIN_HANDS else "right")
	cfg.set_value("look", "fov", roundf(clamp_to(fov, FOVS, DEFAULT_FOV)))
	cfg.set_value("display", "scale", snappedf(clamp_to(render_scale, RENDER_SCALES, 1.0), 0.01))
	cfg.set_value("display", "fullscreen", fullscreen)
	cfg.set_value("display", "vsync", vsync)
	cfg.set_value("display", "ui_scale", snappedf(clamp_to(ui_scale, UI_SCALES, 1.0), 0.01))
	cfg.set_value("weather", "quality", clampi(weather_quality, WeatherView.MINIMAL, WeatherView.HIGH))
	cfg.set_value("controls", "context_menu", clampi(context_menu, MENU_HOLD, MENU_LIST))
	cfg.set_value("sound", "volume", snappedf(clamp_to(volume, VOLUMES, 1.0), 0.01))
	cfg.set_value("sound", "ambience", snappedf(clamp_to(ambience_volume, VOLUMES, 1.0), 0.01))
	for id: String in EYE_FEATURES:
		cfg.set_value("eyes", id, eye_switch(id))
	return cfg.save(path)
