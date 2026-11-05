class_name DirectionRequestWidget
extends RequestWidget
## `direction` requests (choose_direction, choose_adjacent): a 3x3 pad of arrows relative to the screen (up =
## ahead of the camera, through `direction_mapper`), Here in the middle, Up/Down levels when
## `allow_vertical`. Keys: arrows / numpad, KP5 or . = here, < up, > down, Esc cancels.
## Answer: `pos` relative to the player, each axis -1..1 (z 0 unless vertical).

const PAD := [   # (right, forward) on screen, label
	[Vector2(-1, 1), "↖"], [Vector2(0, 1), "↑"], [Vector2(1, 1), "↗"],
	[Vector2(-1, 0), "←"], [Vector2.ZERO, "Here"], [Vector2(1, 0), "→"],
	[Vector2(-1, -1), "↙"], [Vector2(0, -1), "↓"], [Vector2(1, -1), "↘"],
]

var allow_vertical := false
var pad: Array[Button] = []
var up_button: Button
var down_button: Button


func setup(req: Dictionary) -> void:
	super(req)
	allow_vertical = bool_of(req, "allow_vertical", false)
	add_header(req)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_child(grid)
	for p: Array in PAD:
		var b := add_button(p[1], choose.bind(p[0]), grid)
		b.custom_minimum_size = Vector2(60, 44)
		if p[0] != Vector2.ZERO:
			b.add_theme_font_size_override("font_size", 24)
		pad.append(b)
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(bar)
	if allow_vertical:
		up_button = add_button("Up (<)", choose_vertical.bind(1), bar)
		down_button = add_button("Down (>)", choose_vertical.bind(-1), bar)
	if allow_cancel:
		add_button("Cancel (Esc)", cancel, bar)
	add_hint("Arrows / numpad: direction (up = ahead)  KP5 or . here" + ("  < > up/down" if allow_vertical else "") +
			("  Esc cancel" if allow_cancel else ""))


## Answers the step for a screen direction (Vector2.ZERO = the player's own square).
func choose(screen: Vector2) -> void:
	var s := Vector2i.ZERO if screen == Vector2.ZERO else map_step(screen)
	send({"pos": Vector3i(s.x, s.y, 0)})


func choose_vertical(dz: int) -> void:
	if allow_vertical:
		send({"pos": Vector3i(0, 0, signi(dz))})


func handle_input(event: InputEvent) -> bool:
	var key := key_of(event)
	if key == KEY_NONE:
		return false
	var c := char_of(event)
	if c == "<" or c == ">":
		choose_vertical(1 if c == "<" else -1)
	elif c == "." or key == KEY_KP_5 or key == KEY_KP_PERIOD:
		choose(Vector2.ZERO)
	elif MOVE_KEYS.has(key):
		choose(MOVE_KEYS[key])
	elif key == KEY_ESCAPE:
		cancel()
	else:
		return false
	return true
