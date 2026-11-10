class_name CheatPanel
extends VBoxContainer
## K7: the "Cheats" page of the F1 menu (KeyMenu.add_cheat_page), shown only when the debug setting is on
## (HudSettings.debug_cheats) or the game was started with --test / --cheats. It draws CheatModel's rows (shared
## with the VR page): one toggle per bridge cheat, "Auto-pause on hostiles" and "Give test kit". The toggles always
## show what the sim says (CheatModel.read, asked again on each refresh), never a copy kept here: a cheat asked
## for applies at the sim's next request, and cheats_changed brings the new state.
## `backend` is a LiveSession (or a test stand-in with the same methods); null = no live game.

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
	var row := HBoxContainer.new()
	for r: Dictionary in CheatModel.rows({}, false):
		var key: String = r["key"]
		if r["kind"] == CheatModel.ACTION:
			kit_button = Button.new()
			kit_button.text = r["label"]
			kit_button.tooltip_text = "Backpack, guns and ammo, tools, light, food and water; what doesn't fit drops at your feet."
			kit_button.focus_mode = Control.FOCUS_NONE
			kit_button.pressed.connect(give_kit)
			row.add_child(kit_button)
			continue
		var b := CheckButton.new()
		b.text = r["label"]
		b.focus_mode = Control.FOCUS_NONE   # keys stay with the menu
		b.toggled.connect(_on_toggled.bind(key))
		if key == CheatModel.AUTO_PAUSE:
			auto_pause = b
			row.add_child(b)
		else:
			grid.add_child(b)
			toggles[key] = b
	add_child(row)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status)


## Shows the sim's cheats and auto-pause as they are now; everything greyed out without a running game.
func refresh() -> void:
	var live := false
	for r: Dictionary in CheatModel.read(backend):
		var key: String = r["key"]
		live = live or r["enabled"]
		var b: BaseButton = kit_button if key == CheatModel.TEST_KIT else (auto_pause if key == CheatModel.AUTO_PAUSE
				else toggles[key])
		b.disabled = not r["enabled"]
		if b is CheckButton:
			b.set_pressed_no_signal(r["on"])
	if not live:
		_say("Cheats need a running live game (start with --live).", true)


## LiveSession.cheats_changed: the sim applied a change (also one made elsewhere, like --cheats).
func on_cheats_changed(_c: Dictionary) -> void:
	if visible:
		refresh()


func give_kit() -> void:
	if CheatModel.apply(backend, CheatModel.TEST_KIT):
		_say("Test kit asked for: it arrives at the next turn.", false)
	else:
		_say("No test kit: no running game.", true)


func _on_toggled(on: bool, key: String) -> void:
	if not CheatModel.apply(backend, key, on):
		_say("Not changed: no running game.", true)
		refresh()
	elif key != CheatModel.AUTO_PAUSE:
		_say("%s %s: applies at the next turn." % [CheatModel.LABELS[key], "on" if on else "off"], false)


func _say(text: String, warn: bool) -> void:
	status.text = text
	status.add_theme_color_override("font_color", WARN if warn else Color.WHITE)
