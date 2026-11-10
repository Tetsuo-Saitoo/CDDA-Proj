class_name CheatPanel
extends VBoxContainer
## K7: the "Cheats" page of the F1 menu (KeyMenu.add_cheat_page), shown only when the debug setting is on
## (HudSettings.debug_cheats) or the game was started with --test / --cheats. One toggle per bridge cheat
## (LiveSession.CHEATS), a "Give test kit" button and the "Auto-pause on hostiles" setting. The toggles always
## show what the sim says (backend.cheats(), asked again on each refresh), never a copy kept here: a cheat asked
## for applies at the sim's next request, and cheats_changed brings the new state.
## `backend` is a LiveSession (or a test stand-in with the same methods); null = no live game.

const LABELS := {
	"invincible": "No damage (can't die)",
	"no_needs": "No hunger, thirst or sleepiness",
	"no_weight_limit": "No weight limit",
	"unlimited_ammo": "Unlimited ammo (wielded gun)",
	"stamina": "Unlimited stamina",
	"no_temperature": "No heat or cold",
	"night_vision": "Night vision (also reveals the map)",
}
const WARN := Color(1.0, 0.75, 0.3)

var backend: Object
var toggles := {}   # cheat name -> CheckButton
var kit_button: Button
var auto_pause: CheckButton
var status: Label


func _init() -> void:
	name = "CheatPanel"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	visible = false
	var note := Label.new()
	note.text = ("Testing cheats. They stay with the character in its save; turn them off here. "
			+ "Each one applies at the game's next turn.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", WARN)
	add_child(note)
	var grid := GridContainer.new()
	grid.columns = 2
	add_child(grid)
	for n: String in LiveSession.CHEATS:
		var b := CheckButton.new()
		b.text = LABELS.get(n, n)
		b.focus_mode = Control.FOCUS_NONE   # keys stay with the menu
		b.toggled.connect(_on_toggled.bind(n))
		grid.add_child(b)
		toggles[n] = b
	var row := HBoxContainer.new()
	add_child(row)
	kit_button = Button.new()
	kit_button.text = "Give test kit"
	kit_button.tooltip_text = "Backpack, guns and ammo, tools, light, food and water; what doesn't fit drops at your feet."
	kit_button.focus_mode = Control.FOCUS_NONE
	kit_button.pressed.connect(give_kit)
	row.add_child(kit_button)
	auto_pause = CheckButton.new()
	auto_pause.text = "Auto-pause on hostiles (real time)"
	auto_pause.focus_mode = Control.FOCUS_NONE
	auto_pause.toggled.connect(_on_auto_pause)
	row.add_child(auto_pause)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status)


## Shows the sim's cheats and auto-pause as they are now; everything greyed out without a running game.
func refresh() -> void:
	var c: Dictionary = backend.cheats() if _live() else {}
	var on := not c.is_empty()
	for n: String in toggles:
		var b: CheckButton = toggles[n]
		b.disabled = not on
		var v: Variant = c.get(n, false)
		b.set_pressed_no_signal(on and v is bool and v)
	kit_button.disabled = not on
	auto_pause.disabled = not on
	auto_pause.set_pressed_no_signal(on and backend.auto_pause())
	if not on:
		_say("Cheats need a running live game (start with --live).", true)


## LiveSession.cheats_changed: the sim applied a change (also one made elsewhere, like --cheats).
func on_cheats_changed(_c: Dictionary) -> void:
	if visible:
		refresh()


func give_kit() -> void:
	if _live() and backend.give_test_kit():
		_say("Test kit asked for: it arrives at the next turn.", false)
	else:
		_say("No test kit: no running game.", true)


func _on_toggled(on: bool, cheat: String) -> void:
	if _live() and backend.set_cheat(cheat, on):
		_say("%s %s: applies at the next turn." % [LABELS.get(cheat, cheat), "on" if on else "off"], false)
	else:
		_say("Not changed: no running game.", true)
		refresh()


func _on_auto_pause(on: bool) -> void:
	if not (_live() and backend.set_auto_pause(on)):
		_say("Not changed: no running game.", true)
		refresh()


func _live() -> bool:
	return backend != null and is_instance_valid(backend)


func _say(text: String, warn: bool) -> void:
	status.text = text
	status.add_theme_color_override("font_color", WARN if warn else Color.WHITE)
