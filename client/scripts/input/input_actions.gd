class_name InputActions
extends RefCounted
## Stand-in for block E1's action map: every key the game itself reads is a named Godot action with default
## bindings, and the player can rebind them (KeyMenu, F1). Changed bindings live in `user://keys.json`; only
## actions that differ from the defaults are written, so new defaults still reach old files. The file is
## treated as hostile: size-capped, only known actions, at most MAX_SLOTS keys each, only key / mouse button /
## pad button / pad axis entries in a fixed text form. Keys are physical (the same place on any layout).
## Prompt keys (Enter, Esc, arrows in lists, 1-9 picks) and F1 itself stay fixed.

const DEADZONE := 0.3
const FILE := "user://keys.json"
const MAX_FILE_BYTES := 65536
const MAX_SLOTS := 4          # keys per action kept from the file
const MENU_KEY := KEY_F1      # opens the key menu; fixed so it can't be lost

## Every action: [name, group, label, default bindings]. A binding is the text form `event_text` reads:
## "W", "Shift+E", "Kp 8", "mouse:1" (left) / "mouse:2" (right), "pad:0", "axis:1-" / "axis:1+".
const ACTIONS := [
	[&"move_forward", "Move", "forward", ["W", "axis:1-"]],
	[&"move_back", "Move", "back", ["S", "axis:1+"]],
	[&"move_left", "Move", "left", ["A", "axis:0-"]],
	[&"move_right", "Move", "right", ["D", "axis:0+"]],
	[&"move_fast", "Move", "fast (outside view, mock)", ["Shift"]],
	[&"level_up", "Move", "level up / stairs up", ["BracketRight"]],
	[&"level_down", "Move", "level down / stairs down", ["BracketLeft"]],
	[&"step_forward", "Move", "step forward (live)", ["Up", "Kp 8"]],
	[&"step_back", "Move", "step back (live)", ["Down", "Kp 2"]],
	[&"step_left", "Move", "step left (live)", ["Left", "Kp 4"]],
	[&"step_right", "Move", "step right (live)", ["Right", "Kp 6"]],
	[&"step_forward_left", "Move", "step forward-left (live)", ["Kp 7"]],
	[&"step_forward_right", "Move", "step forward-right (live)", ["Kp 9"]],
	[&"step_back_left", "Move", "step back-left (live)", ["Kp 1"]],
	[&"step_back_right", "Move", "step back-right (live)", ["Kp 3"]],
	[&"wait", "Move", "wait a turn (live)", ["Kp 5", "Period"]],
	[&"look", "View", "hold: mouse look", ["mouse:2"]],
	[&"look_up", "View", "look up", ["axis:3-"]],
	[&"look_down", "View", "look down", ["axis:3+"]],
	[&"look_left", "View", "look left", ["axis:2-"]],
	[&"look_right", "View", "look right", ["axis:2+"]],
	[&"look_at", "View", "look at what you point at; aiming: pick a target, again to fire", ["mouse:1"]],
	[&"view_toggle", "View", "first person / outside", ["V"]],
	[&"fly_up", "View", "fly up (outside)", ["E", "Space"]],
	[&"fly_down", "View", "fly down (outside)", ["Q", "Ctrl"]],
	[&"cutaway_up", "View", "show a level more", ["PageUp"]],
	[&"cutaway_down", "View", "show a level less", ["PageDown"]],
	[&"roofs_toggle", "View", "roofs on / off", ["Y"]],
	[&"frame_player", "View", "back to the player", ["Home"]],
	[&"reload", "View", "reload the snapshot (mock)", ["F9"]],
	[&"save_game", "Act", "save the game (live)", ["F5"]],
	[&"hand_off", "Act", "strike, left (off) hand", ["1"]],
	[&"hand_main", "Act", "strike, right (main) hand", ["2"]],
	[&"use_held", "Act", "take the item you look at / use what you hold on what you face / examine it", ["E"]],
	[&"carry_farther", "Act", "carrying an item: hold it farther away", ["mouse:4"]],
	[&"carry_closer", "Act", "carrying an item: hold it closer", ["mouse:5"]],
	[&"carry_turn_left", "Act", "carrying an item: turn it left", ["mouse:Shift+4"]],
	[&"carry_turn_right", "Act", "carrying an item: turn it right", ["mouse:Shift+5"]],
	[&"inspect", "Act", "look into a container / your backpack", ["Tab"]],
	[&"hold_off", "Act", "hold an item in the left (off) hand", ["H"]],
	[&"stow_off", "Act", "put away the left hand's item", ["Shift+H"]],
	[&"cdda_examine", "Act", "examine (pick a direction)", ["X"]],
	[&"cdda_pickup", "Act", "pick up", ["G"]],
	[&"cdda_inventory", "Act", "inventory", ["I"]],
	[&"cdda_open", "Act", "open", ["O"]],
	[&"cdda_close", "Act", "close", ["C"]],
	[&"cdda_wield", "Act", "wield", ["Q"]],
	[&"cdda_apply", "Act", "apply / use", ["U"]],
	[&"cdda_smash", "Act", "smash", ["Z"]],
	[&"cdda_throw", "Act", "throw", ["T"]],
	[&"cdda_fire", "Act", "fire; aiming: fire at the target", ["F"]],
	[&"cdda_reload", "Act", "reload the wielded gun", ["R"]],
	[&"aim_fire", "Act", "aiming: fire at the crosshair / target", ["pad:10"]],
	[&"cdda_eat", "Act", "eat", ["Shift+E"]],
	[&"cdda_wear", "Act", "wear", ["Shift+W"]],
	[&"cdda_take_off", "Act", "take off", ["Shift+T"]],
	[&"cdda_read", "Act", "read", ["Shift+R"]],
	[&"cdda_drop", "Act", "drop", ["Shift+D"]],
	[&"cdda_unload", "Act", "unload", ["Shift+U"]],
	[&"cdda_butcher", "Act", "butcher", ["Shift+B"]],
	[&"cdda_grab", "Act", "grab", ["Shift+G"]],
	[&"cdda_safemode", "Act", "safe mode on / off", ["Shift+1"]],
]
## Live game: action -> CDDA main-loop action. CDDA then asks what it needs (which item, which way) through
## the usual prompts. Left out: CDDA's own screens (map, crafting, character sheet, look around), which the
## client can't draw yet.
const CDDA := {
	&"cdda_examine": "examine", &"cdda_pickup": "pickup", &"cdda_inventory": "inventory", &"cdda_open": "open",
	&"cdda_close": "close", &"cdda_wield": "wield", &"cdda_apply": "apply", &"cdda_smash": "smash",
	&"cdda_throw": "throw", &"cdda_fire": "fire", &"cdda_reload": "reload_weapon", &"cdda_eat": "eat", &"cdda_wear": "wear",
	&"cdda_take_off": "take_off", &"cdda_read": "read", &"cdda_drop": "drop", &"cdda_unload": "unload",
	&"cdda_butcher": "butcher", &"cdda_grab": "grab", &"cdda_safemode": "safemode",
}
## Live steps: action -> (right, forward) relative to where you look.
const STEPS := {
	&"step_forward": Vector2(0, 1), &"step_back": Vector2(0, -1), &"step_left": Vector2(-1, 0),
	&"step_right": Vector2(1, 0), &"step_forward_left": Vector2(-1, 1), &"step_forward_right": Vector2(1, 1),
	&"step_back_left": Vector2(-1, -1), &"step_back_right": Vector2(1, -1),
}
const _MODS := ["Shift+", "Ctrl+", "Alt+", "Meta+"]


static func names() -> Array[StringName]:
	var out: Array[StringName] = []
	for a: Array in ACTIONS:
		out.append(a[0])
	return out


static func info(action: StringName) -> Array:
	for a: Array in ACTIONS:
		if a[0] == action:
			return a
	return []


static func defaults(action: StringName) -> Array[InputEvent]:
	var out: Array[InputEvent] = []
	var a := info(action)
	for t: String in (a[3] if not a.is_empty() else []):
		var e := parse_event(t)
		if e != null:
			out.append(e)
	return out


## Adds missing actions with their defaults (bindings already there win, e.g. from project.godot), then
## applies `user://keys.json` unless `load_file` is false (tests). Returns problems found in the file.
static func ensure(load_file := true) -> PackedStringArray:
	for a in names():
		if InputMap.has_action(a):
			continue
		InputMap.add_action(a, DEADZONE)
		for e in defaults(a):
			InputMap.action_add_event(a, e)
	return load_bindings(FILE) if load_file else PackedStringArray()


## True when `event` is a fresh press of `action` with exactly its modifiers (Shift+E isn't E).
static func pressed(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and event.is_action_pressed(action, false, true)


## Keyboard and mouse bindings of an action (pad ones: pad_slots).
static func slots(action: StringName) -> Array[InputEvent]:
	var out: Array[InputEvent] = []
	if InputMap.has_action(action):
		for e in InputMap.action_get_events(action):
			if e is InputEventKey or e is InputEventMouseButton:
				out.append(e)
	return out


## First key of an action as short text for the HUD ("-" when unbound).
static func key_of(action: StringName) -> String:
	var s := slots(action)
	return event_label(s[0]) if not s.is_empty() else "-"


## Replaces the keyboard/mouse bindings of an action (pad bindings stay).
static func set_slots(action: StringName, events: Array[InputEvent]) -> void:
	if not InputMap.has_action(action):
		return
	for e in slots(action):
		InputMap.action_erase_event(action, e)
	for e in events.slice(0, MAX_SLOTS):
		InputMap.action_add_event(action, e)


## How far a stick or trigger must be pushed for the key menu to take it as a binding.
const PAD_PUSH := 0.6


static func is_pad(e: InputEvent) -> bool:
	return e is InputEventJoypadButton or e is InputEventJoypadMotion


## Pad bindings of an action: buttons and stick / trigger directions (the key menu's Pad column).
static func pad_slots(action: StringName) -> Array[InputEvent]:
	var out: Array[InputEvent] = []
	if InputMap.has_action(action):
		for e in InputMap.action_get_events(action):
			if is_pad(e):
				out.append(e)
	return out


## Replaces the pad bindings of an action (keyboard and mouse stay).
static func set_pad_slots(action: StringName, events: Array[InputEvent]) -> void:
	if not InputMap.has_action(action):
		return
	for e in pad_slots(action):
		InputMap.action_erase_event(action, e)
	for e in events.slice(0, MAX_SLOTS):
		if is_pad(e):
			InputMap.action_add_event(action, e)


## A captured pad press as a binding (the same form keys.json reads back): a button going down, or a stick /
## trigger pushed past PAD_PUSH one way. null for anything else (releases, small or NaN motion).
static func pad_binding_from(e: InputEvent) -> InputEvent:
	if e is InputEventJoypadButton:
		var b := e as InputEventJoypadButton
		return parse_event("pad:%d" % b.button_index) if b.pressed else null
	if e is InputEventJoypadMotion:
		var m := e as InputEventJoypadMotion
		if not absf(m.axis_value) >= PAD_PUSH:   # also refuses NaN
			return null
		return parse_event("axis:%d%s" % [m.axis, "-" if m.axis_value < 0.0 else "+"])
	return null


## Other actions bound to exactly this event.
static func users_of(event: InputEvent, except: StringName = &"") -> Array[StringName]:
	var out: Array[StringName] = []
	var t := event_text(event)
	for a in names():
		if a == except or not InputMap.has_action(a):
			continue
		for e in InputMap.action_get_events(a):
			if event_text(e) == t:
				out.append(a)
				break
	return out


static func reset_all() -> void:
	for a in names():
		if InputMap.has_action(a):
			InputMap.action_erase_events(a)
		else:
			InputMap.add_action(a, DEADZONE)
		for e in defaults(a):
			InputMap.action_add_event(a, e)


## Text form of a binding, "" for kinds this map doesn't keep.
static func event_text(e: InputEvent) -> String:
	if e is InputEventKey:
		var k := e as InputEventKey
		var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		if code == KEY_NONE:
			return ""
		return _mods_text(k) + OS.get_keycode_string(code)
	if e is InputEventMouseButton:
		return "mouse:" + _mods_text(e) + str((e as InputEventMouseButton).button_index)
	if e is InputEventJoypadButton:
		return "pad:%d" % (e as InputEventJoypadButton).button_index
	if e is InputEventJoypadMotion:
		var m := e as InputEventJoypadMotion
		return "axis:%d%s" % [m.axis, "-" if m.axis_value < 0.0 else "+"]
	return ""


## Binding from its text form, or null for anything malformed or out of range.
static func parse_event(t: String) -> InputEvent:
	if t.is_empty() or t.length() > 40:
		return null
	if t.begins_with("pad:"):
		var n := t.substr(4)
		if not n.is_valid_int() or n.to_int() < 0 or n.to_int() >= JOY_BUTTON_SDL_MAX:
			return null
		var b := InputEventJoypadButton.new()
		b.button_index = n.to_int() as JoyButton
		return b
	if t.begins_with("axis:"):
		var s := t.substr(5)
		var n := s.left(-1)
		if (s.length() < 2 or not s[-1] in ["-", "+"] or not n.is_valid_int() or n.to_int() < 0
				or n.to_int() >= JOY_AXIS_SDL_MAX):
			return null
		var m := InputEventJoypadMotion.new()
		m.axis = n.to_int() as JoyAxis
		m.axis_value = -1.0 if s[-1] == "-" else 1.0
		return m
	var mouse := t.begins_with("mouse:")
	var rest := t.substr(6) if mouse else t
	var mods := [false, false, false, false]
	var found := true
	while found:
		found = false
		for i in _MODS.size():
			if rest.begins_with(_MODS[i]) and rest.length() > _MODS[i].length():
				mods[i] = true
				rest = rest.substr(_MODS[i].length())
				found = true
	var e: InputEventWithModifiers
	if mouse:
		if not rest.is_valid_int() or rest.to_int() < 1 or rest.to_int() > 9:
			return null
		var mb := InputEventMouseButton.new()
		mb.button_index = rest.to_int() as MouseButton
		e = mb
	else:
		var code := OS.find_keycode_from_string(rest)
		if code == KEY_NONE or OS.get_keycode_string(code) != rest:
			return null
		var k := InputEventKey.new()
		k.physical_keycode = code
		e = k
	e.shift_pressed = mods[0]
	e.ctrl_pressed = mods[1]
	e.alt_pressed = mods[2]
	e.meta_pressed = mods[3]
	return e


## Short label for the menu and HUD: "W", "Shift+E", "LMB", "RMB", "Mouse 4", "Pad A", "Pad R1", "L stick up".
static func event_label(e: InputEvent) -> String:
	var t := event_text(e)
	if e is InputEventMouseButton:
		var names := {1: "LMB", 2: "RMB", 3: "MMB", 4: "Wheel up", 5: "Wheel down"}
		var b := (e as InputEventMouseButton).button_index as int
		return _mods_text(e) + str(names.get(b, "Mouse %d" % b))
	if e is InputEventJoypadButton:
		var pad := ["A", "B", "X", "Y", "Back", "Guide", "Start", "L3", "R3", "L1", "R1", "D-pad up", "D-pad down",
				"D-pad left", "D-pad right"]
		var i := (e as InputEventJoypadButton).button_index as int
		if i < 0 or i >= pad.size():
			return "Pad %d" % i
		return "Pad " + pad[i]
	if e is InputEventJoypadMotion:
		var m := e as InputEventJoypadMotion
		var neg := m.axis_value < 0.0
		var axes := ["L stick " + ("left" if neg else "right"), "L stick " + ("up" if neg else "down"),
				"R stick " + ("left" if neg else "right"), "R stick " + ("up" if neg else "down"), "L2", "R2"]
		var a := m.axis as int
		if a < 0 or a >= axes.size():
			return "Axis %d%s" % [a, "-" if neg else "+"]
		return axes[a] + (" -" if a >= 4 and neg else "")   # triggers rest at 0 and push +
	return t


## A captured press as a binding: physical key with its modifiers (a modifier key alone has none), or a
## mouse button with its modifiers. null for anything else.
static func binding_from(e: InputEvent) -> InputEvent:
	if e is InputEventKey:
		var k := e as InputEventKey
		var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		if code == KEY_NONE:
			return null
		var out := InputEventKey.new()
		out.physical_keycode = code
		if not code in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
			out.shift_pressed = k.shift_pressed
			out.ctrl_pressed = k.ctrl_pressed
			out.alt_pressed = k.alt_pressed
			out.meta_pressed = k.meta_pressed
		return out
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index < 1 or mb.button_index > 9:
			return null
		var out := InputEventMouseButton.new()
		out.button_index = mb.button_index
		out.shift_pressed = mb.shift_pressed
		out.ctrl_pressed = mb.ctrl_pressed
		out.alt_pressed = mb.alt_pressed
		out.meta_pressed = mb.meta_pressed
		return out
	return null


## Writes the actions that differ from their defaults. Returns "" or an error.
static func save_bindings(path := FILE) -> String:
	var changed := {}
	for a in names():
		var now := _texts(InputMap.action_get_events(a) if InputMap.has_action(a) else [])
		if now != _texts(defaults(a)):
			changed[String(a)] = now
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "can't write %s (%s)" % [path, error_string(FileAccess.get_open_error())]
	f.store_string(JSON.stringify({"version": 1, "actions": changed}, "\t"))
	return ""


## Applies a bindings file; a missing file is fine. Returns what was wrong with it (entries skipped).
static func load_bindings(path := FILE) -> PackedStringArray:
	var bad := PackedStringArray()
	if not FileAccess.file_exists(path):
		return bad
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		bad.append("can't read %s" % path)
		return bad
	if f.get_length() > MAX_FILE_BYTES:
		bad.append("%s is over %d bytes, ignored" % [path, MAX_FILE_BYTES])
		return bad
	var json := JSON.new()   # parse() doesn't print errors the way JSON.parse_string does
	var d: Variant = json.data if json.parse(f.get_as_text()) == OK else null
	if not d is Dictionary or not (d as Dictionary).get("actions") is Dictionary:
		bad.append("%s isn't a key file, ignored" % path)
		return bad
	var acts: Dictionary = d["actions"]
	for key: Variant in acts:
		var a := StringName(str(key))
		if not key is String or info(a).is_empty():
			bad.append("unknown action %s" % str(key).left(40))
			continue
		if not acts[key] is Array:
			bad.append("%s: not a list" % a)
			continue
		var events: Array[InputEvent] = []
		for t: Variant in acts[key]:
			var e := parse_event(t) if t is String else null
			if e == null:
				bad.append("%s: bad key %s" % [a, str(t).left(40)])
			elif events.size() < MAX_SLOTS * 2 and not _texts(events).has(event_text(e)):
				events.append(e)
		InputMap.action_erase_events(a)
		for e in events:
			InputMap.action_add_event(a, e)
		if bad.size() > 20:
			bad.append("too many problems, stopped")
			break
	return bad


static func _texts(events: Array) -> Array[String]:
	var out: Array[String] = []
	for e: InputEvent in events:
		var t := event_text(e)
		if t != "":
			out.append(t)
	return out


static func _mods_text(e: InputEventWithModifiers) -> String:
	return (("Shift+" if e.shift_pressed else "") + ("Ctrl+" if e.ctrl_pressed else "")
			+ ("Alt+" if e.alt_pressed else "") + ("Meta+" if e.meta_pressed else ""))
