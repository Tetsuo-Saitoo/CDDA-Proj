class_name TeleportPick
extends RefCounted
## The teleport cheat's other targets (user, 2026-11-17: with zombies all around, the crosshair lands on them).
## - The look-at marker: L / middle click (look_at), while teleporting is allowed, remembers the square TeleportAim
##   gives for what was looked at (`marked`); main draws a marker there, and J while that look is open goes there
##   instead of to the crosshair. Closing or replacing the look forgets it.
## - "Teleport: pick a square" (the F1 cheats page): `picking` until the next left click (main teleports to the
##   square under it), Esc or a right click (cancelled). Main reads every event through pick_event first.
## J itself aims through creatures (main: LookRay without them), so it lands on the floor beyond.

enum { NONE, PICK, CANCEL }

var marked: Variant = null   # the open look's teleport square (Vector3i); null: no look, or teleport not allowed
var picking := false


## While picking, what `event` does: PICK (a left click: teleport to the square under it), CANCEL (Esc or a right
## click), NONE (anything else, or not picking). PICK and CANCEL end the picking.
func pick_event(event: InputEvent) -> int:
	if not picking or event == null:
		return NONE
	var what := NONE
	var m := event as InputEventMouseButton
	var k := event as InputEventKey
	if m != null and m.pressed:
		if m.button_index == MOUSE_BUTTON_LEFT:
			what = PICK
		elif m.button_index == MOUSE_BUTTON_RIGHT:
			what = CANCEL
	elif k != null and k.pressed and not k.echo and (k.physical_keycode == KEY_ESCAPE or k.keycode == KEY_ESCAPE):
		what = CANCEL
	if what != NONE:
		picking = false
	return what


## The look panel's line for the marker ("" when there is none): `key` is cheat_teleport's key.
func look_line(key: String) -> String:
	return "%s: teleport here (the marker)" % key if marked is Vector3i else ""
