class_name Hints
extends PanelContainer
## G6 onboarding (flat screen): one-time hints at the top right. main calls trigger(id) when the moment comes (the
## first turn in a game, the first Tab view, the first question from the game, and what due() finds in a snapshot:
## the first hostile in sight, hunger or thirst, bleeding); each id shows once, ever,
## for SHOW_S seconds, one after another. `{action}` in a text becomes that action's first key (InputActions.key_of),
## so a rebound key reads right. Seen ids and the on / off switch (the F1 menu's Hints box) are kept in
## user://hints.cfg, read as hostile: size cap, no Object(...), only known ids, a non-bool leaves hints on.

const FILE := "user://hints.cfg"
const MAX_FILE_BYTES := 8 << 10
const SHOW_S := 14.0
const MAX_QUEUE := 8
const TEXTS := {
	"start": "Hold {look} and move the mouse to look around; {step_forward} {step_left} {step_back} {step_right} or "
			+ "the number pad take a step. {use_held} takes or uses what you look at, {inspect} shows your things and "
			+ "the ground, {character} your character. F1: keys and options.",
	"inspect": "Drag items between your hands, your bags and the ground. Select one and press {hotbar_1} to "
			+ "{hotbar_8} to put it on the hotbar; that key then takes it into your hand. {inspect} or Esc closes.",
	"prompt": "The game is asking: click a choice or press its key. Esc cancels.",
	"hostile": "Something hostile is in sight (red on the compass). Step into it to attack, or strike with "
			+ "{hand_main} (main hand) or {hand_off} (off hand); {cdda_fire} fires a gun you hold.",
	"eat": "Hungry or thirsty: hold food or a drink and press {cdda_eat}; with empty hands {cdda_eat} lists "
			+ "what you can eat or drink.",
	"bleed": "You are bleeding (the body bars at the left show where): press {cdda_apply} and pick a bandage or a "
			+ "first aid kit.",
}
## CDDA's hunger effects that mean "eat something" (not full, not engorged).
const HUNGRY_EFFECTS := ["hunger_hungry", "hunger_very_hungry", "hunger_near_starving", "hunger_starving",
		"hunger_famished"]

var path := UserFiles.at(FILE)   # a test run's own folder
## False: nothing is written (main, under a test runner's own SceneTree script: a test never uses up the player's
## hints).
var persist := true
var enabled := true
var seen := {}                   # id -> true, once triggered
var queue: Array[String] = []    # ids waiting to show
var shown := ""                  # the id on screen, "" none
var _left := 0.0
var _label: Label


func _init() -> void:
	name = "Hints"
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	offset_right = -12
	offset_top = 44
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size = Vector2(380, 0)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	visible = false


## `text` with each {action} as its first key ("-" unbound); an unknown name stays as written, without braces.
static func fill(text: String) -> String:
	var out := text
	var i := out.find("{")
	while i >= 0:
		var j := out.find("}", i)
		if j < 0:
			break
		var act := StringName(out.substr(i + 1, j - i - 1))
		var key := InputActions.key_of(act) if InputMap.has_action(act) else String(act)
		out = out.substr(0, i) + key + out.substr(j + 1)
		i = out.find("{", i + key.length())
	return out


## The hints the game calls for now (main asks each snapshot in play): "hostile" for a hostile creature in sight,
## "eat" for hunger (HUNGRY_EFFECTS) or thirst (HudData's HURT or worse), "bleed" for a bleeding body part.
## trigger() then refuses the ones already seen.
static func due(snap: Snapshot, hud: HudData) -> Array[String]:
	var out: Array[String] = []
	if snap != null and snap.creatures.any(func(c: Snapshot.Creature) -> bool: return c.is_hostile()):
		out.append("hostile")
	var hungry := snap != null and snap.player_effects.any(func(e: Dictionary) -> bool:
		return str(e.get("id", "")) in HUNGRY_EFFECTS)
	var thirst: Variant = hud.needs.get("thirst", {}).get("level", HudData.UNKNOWN) if hud != null else null
	if hungry or (thirst is int and thirst >= HudData.HURT):
		out.append("eat")
	if hud != null and hud.body.any(func(p: Dictionary) -> bool: return int(p.get("bleed", 0)) > 0):
		out.append("bleed")
	return out


## Shows hint `id` once (queued behind the one showing). False when off, unknown or already seen.
func trigger(id: String) -> bool:
	if not enabled or not TEXTS.has(id) or seen.has(id) or queue.size() >= MAX_QUEUE:
		return false
	seen[id] = true
	var err := save_file()
	if err != OK:
		push_warning("hints not saved: %s" % error_string(err))
	queue.append(id)
	if shown == "":
		_next()
	return true


## The hint on screen goes; the next one waiting shows.
func dismiss() -> void:
	_next()


## Counts the shown hint down by `delta` seconds (main's frame; tests call it).
func tick(delta: float) -> void:
	if shown == "":
		return
	_left -= delta
	if _left <= 0.0:
		_next()


func _process(delta: float) -> void:
	tick(delta)


## The F1 menu's Hints box: off clears what is showing or waiting. Saved.
func set_enabled(on: bool) -> void:
	enabled = on
	if not on:
		queue.clear()
		_next()
	save_file()


## The F1 menu's "Show hints again": every hint can show once more. Saved.
func reset() -> void:
	seen.clear()
	save_file()


func _next() -> void:
	if queue.is_empty():
		shown = ""
		visible = false
		return
	shown = queue.pop_front()
	_label.text = fill(TEXTS[shown])
	_left = SHOW_S
	visible = true


## Reads the file; returns "" or why it was ignored (missing is not an error).
func load_file() -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "cannot open %s" % path
	if f.get_length() > MAX_FILE_BYTES:
		return "%s is over %d bytes" % [path, MAX_FILE_BYTES]
	var text := f.get_as_text()
	for bad: String in ["Object(", "Resource(", "ExtResource(", "SubResource("]:
		if bad in text:
			return "%s has %s, ignored" % [path, bad]
	var cfg := ConfigFile.new()
	if cfg.parse(text) != OK:
		return "%s doesn't parse" % path
	var on: Variant = cfg.get_value("hints", "enabled", true)
	enabled = on if on is bool else true
	seen.clear()
	var v: Variant = cfg.get_value("hints", "seen", [])
	if v is Array or v is PackedStringArray:
		for id: Variant in Array(v).slice(0, 64):
			if id is String and TEXTS.has(id):
				seen[id] = true
	return ""


func save_file() -> Error:
	if not persist:
		return OK
	var cfg := ConfigFile.new()
	cfg.set_value("hints", "enabled", enabled)
	var ids: Array[String] = []
	for id: String in TEXTS:
		if seen.has(id):
			ids.append(id)
	cfg.set_value("hints", "seen", ids)
	return cfg.save(path)
