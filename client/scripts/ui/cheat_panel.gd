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
## K7 test range controls, shown only in a range game (backend.in_range()): zones, monsters frozen, heal, time,
## spawns. Each sends one range_* op; LiveSession.range_done says how it went (on_range_done).
var range_box: VBoxContainer
var zone_pick: OptionButton
var freeze: CheckButton
var hour: SpinBox
var item_id: LineEdit
var item_count: SpinBox
var monster_id: LineEdit
## Item ids to itype indices (the live id tables); main sets it.
var tables: IdTables
## () -> Vector3i: the player's square (items spawn there). Main sets it.
var player_square := Callable()
## () -> Vector3i: a square ahead of where the player looks (monsters spawn there). Main sets it.
var ahead_square := Callable()
var _range_ops := {}   # op id -> what it was, for the status line
const MAX_RANGE_OPS := 32


func _init() -> void:
	name = "CheatPanel"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	visible = false
	var note := Label.new()
	note.text = ("Testing cheats. They stay with the character in its save; turn them off here. "
			+ "Each one applies at the game's next turn. The first cheat or test kit turns this game's "
			+ "achievements off for good.")
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
	_build_range()
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
	refresh_range()
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
		_say("No test kit: no running game, or cheats aren't allowed.", true)


func _on_toggled(on: bool, key: String) -> void:
	if not CheatModel.apply(backend, key, on):
		_say("Not changed: no running game, or cheats aren't allowed.", true)
		refresh()
	elif key != CheatModel.AUTO_PAUSE:
		_say("%s %s: applies at the next turn." % [CheatModel.LABELS[key], "on" if on else "off"], false)


func _build_range() -> void:
	range_box = VBoxContainer.new()
	range_box.name = "Range"
	range_box.visible = false
	add_child(range_box)
	var title := Label.new()
	title.text = "Test range"
	range_box.add_child(title)
	var r1 := HBoxContainer.new()
	zone_pick = OptionButton.new()
	zone_pick.focus_mode = Control.FOCUS_NONE
	zone_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r1.add_child(zone_pick)
	r1.add_child(_button("Go there", go_zone))
	var rb := _button("Rebuild", rebuild_zone)
	rb.tooltip_text = "Clears the zone and builds it again (not while you are in it)."
	r1.add_child(rb)
	range_box.add_child(r1)
	var r2 := HBoxContainer.new()
	freeze = CheckButton.new()
	freeze.text = "Monsters frozen"
	freeze.focus_mode = Control.FOCUS_NONE
	freeze.toggled.connect(set_frozen)
	r2.add_child(freeze)
	r2.add_child(_button("Heal", heal))
	r2.add_child(_button("Wait 1 hour", wait_hour))
	range_box.add_child(r2)
	var r3 := HBoxContainer.new()
	hour = SpinBox.new()
	hour.min_value = 0
	hour.max_value = 23
	hour.value = 12
	hour.suffix = ":00"
	hour.prefix = "Time"
	r3.add_child(hour)
	r3.add_child(_button("Set time", set_time))
	range_box.add_child(r3)
	var r4 := HBoxContainer.new()
	item_id = LineEdit.new()
	item_id.placeholder_text = "item id, e.g. glock_19"
	item_id.max_length = 64
	item_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item_count = SpinBox.new()
	item_count.min_value = 1
	item_count.max_value = RangeInfo.MAX_COUNT
	item_count.value = 1
	r4.add_child(item_id)
	r4.add_child(item_count)
	r4.add_child(_button("Spawn at feet", spawn_item))
	range_box.add_child(r4)
	var r5 := HBoxContainer.new()
	monster_id = LineEdit.new()
	monster_id.placeholder_text = "monster id, e.g. mon_zombie"
	monster_id.max_length = RangeInfo.MAX_MONSTER_ID
	monster_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r5.add_child(monster_id)
	r5.add_child(_button("Spawn ahead", spawn_monster))
	range_box.add_child(r5)


func _button(text: String, f: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(f)
	return b


## Shows the range controls as LiveSession.range_info says (hidden outside a range game).
func refresh_range() -> void:
	var info: Dictionary = backend.range_info() if _has("range_info") else {}
	range_box.visible = info.get("range", false)
	if not range_box.visible:
		return
	var zones: Array = info.get("zones", [])
	var keep := zone_pick.selected
	zone_pick.clear()
	for z: Dictionary in zones:
		zone_pick.add_item("%s%s" % [z["name"], "" if z["built"] else " (not built yet)"])
		zone_pick.set_item_metadata(zone_pick.item_count - 1, z["name"])
	var here: int = info.get("zone", -1)
	zone_pick.select(keep if keep >= 0 and keep < zones.size() else here)
	freeze.set_pressed_no_signal(info.get("ai_frozen", false))


## LiveSession.range_changed.
func on_range_changed(_info: Dictionary) -> void:
	refresh_range()


## LiveSession.range_done: the status line says how an op sent from here went.
func on_range_done(op_id: int, err: String) -> void:
	if not _range_ops.has(op_id):
		return
	var what: String = _range_ops[op_id]
	_range_ops.erase(op_id)
	if err.is_empty():
		_say("%s: done." % what, false)
	else:
		_say("%s: %s" % [what, err], true)


func go_zone() -> void:
	var i := zone_pick.selected
	var zone_name := str(zone_pick.get_item_metadata(i)) if i >= 0 else ""
	_sent("Go to %s" % zone_name if i >= 0 else "Go", backend.range_teleport(i) if i >= 0 and _has("range_teleport") else 0)


func rebuild_zone() -> void:
	var i := zone_pick.selected
	var zone_name := str(zone_pick.get_item_metadata(i)) if i >= 0 else ""
	_sent("Rebuild %s" % zone_name if i >= 0 else "Rebuild",
			backend.range_rebuild_zone(i) if i >= 0 and _has("range_rebuild_zone") else 0)


func set_frozen(on: bool) -> void:
	_sent("Monsters %s" % ("frozen" if on else "moving"), backend.range_set_ai_frozen(on) if _has("range_set_ai_frozen") else 0)


func heal() -> void:
	_sent("Heal", backend.range_heal() if _has("range_heal") else 0)


func wait_hour() -> void:
	_sent("Wait 1 hour", backend.range_advance(60) if _has("range_advance") else 0)


func set_time() -> void:
	var h := int(hour.value)
	_sent("Time %d:00" % h, backend.range_set_time(h * 60) if _has("range_set_time") else 0)


func spawn_item() -> void:
	var id := item_id.text.strip_edges()
	var t := tables.index_of("itype", id) if tables != null and not id.is_empty() else -1
	if t < 1:
		_say("No item type \"%s\" (use a CDDA id, e.g. glock_19)." % id.left(64), true)
		return
	var sq: Variant = player_square.call() if player_square.is_valid() else null
	if not sq is Vector3i or not _has("range_spawn_item"):
		_say("Not sent: no running range game.", true)
		return
	_sent("Spawn %s" % id, backend.range_spawn_item(t, int(item_count.value), sq))


func spawn_monster() -> void:
	var id := monster_id.text.strip_edges()
	if not RangeInfo.monster_id_ok(id):
		_say("Monster ids are letters, digits, _ and - (e.g. mon_zombie).", true)
		return
	var sq: Variant = ahead_square.call() if ahead_square.is_valid() else null
	if not sq is Vector3i or not _has("range_spawn_monster"):
		_say("Not sent: no running range game.", true)
		return
	_sent("Spawn %s" % id, backend.range_spawn_monster(id, sq))


func _sent(what: String, op_id: int) -> void:
	if op_id < 1:
		_say("%s: not sent (no range game, or too many waiting)." % what, true)
		return
	if _range_ops.size() >= MAX_RANGE_OPS:
		_range_ops.erase(_range_ops.keys()[0])
	_range_ops[op_id] = what
	_say("%s: asked for." % what, false)


func _has(method: String) -> bool:
	return backend != null and is_instance_valid(backend) and backend.has_method(method)


func _say(text: String, warn: bool) -> void:
	status.text = text
	status.add_theme_color_override("font_color", WARN if warn else Color.WHITE)
