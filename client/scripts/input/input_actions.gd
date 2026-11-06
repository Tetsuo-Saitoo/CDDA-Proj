class_name InputActions
extends RefCounted
## Stand-in for block E1's action map: default bindings for the Godot actions the client reads (first-person
## view, block C9). `ensure()` only adds actions that are missing, so bindings from project.godot's input map
## (or E1's rebinding later) win. Keys are physical (the same place on any keyboard layout).

const DEADZONE := 0.3
const KEYS := {
	&"move_forward": [KEY_W], &"move_back": [KEY_S], &"move_left": [KEY_A], &"move_right": [KEY_D],
	&"move_fast": [KEY_SHIFT], &"level_up": [KEY_BRACKETRIGHT], &"level_down": [KEY_BRACKETLEFT],
	&"view_toggle": [KEY_V],
}
## Action -> [axis, direction] on the gamepad.
const AXES := {
	&"move_forward": [JOY_AXIS_LEFT_Y, -1.0], &"move_back": [JOY_AXIS_LEFT_Y, 1.0],
	&"move_left": [JOY_AXIS_LEFT_X, -1.0], &"move_right": [JOY_AXIS_LEFT_X, 1.0],
	&"look_up": [JOY_AXIS_RIGHT_Y, -1.0], &"look_down": [JOY_AXIS_RIGHT_Y, 1.0],
	&"look_left": [JOY_AXIS_RIGHT_X, -1.0], &"look_right": [JOY_AXIS_RIGHT_X, 1.0],
}
const BUTTONS := {&"look": MOUSE_BUTTON_RIGHT}   # held: mouse look


static func names() -> Array[StringName]:
	var out: Array[StringName] = []
	for d: Dictionary in [KEYS, AXES, BUTTONS]:
		for a: StringName in d:
			if a not in out:
				out.append(a)
	return out


static func ensure() -> void:
	for a in names():
		if InputMap.has_action(a):
			continue
		InputMap.add_action(a, DEADZONE)
		for code: Key in KEYS.get(a, []):
			var k := InputEventKey.new()
			k.physical_keycode = code
			InputMap.action_add_event(a, k)
		if AXES.has(a):
			var j := InputEventJoypadMotion.new()
			j.axis = AXES[a][0]
			j.axis_value = AXES[a][1]
			InputMap.action_add_event(a, j)
		if BUTTONS.has(a):
			var m := InputEventMouseButton.new()
			m.button_index = BUTTONS[a]
			InputMap.action_add_event(a, m)
