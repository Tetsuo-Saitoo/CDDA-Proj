class_name CheatPanel
extends VBoxContainer
## K7: the "Cheats" page of the F1 menu (KeyMenu.add_cheat_page), shown only when the debug setting is on
## (HudSettings.debug_cheats) or the game was started with --test / --cheats. It draws CheatModel's rows (shared
## with the VR page): one toggle per bridge cheat, "Auto-pause on hostiles", "Give test kit", "Teleport to the
## crosshair" and the weather (CDDA's weather types and a wind, each also "as the game decides"; any game; greyed
## out while cheats aren't allowed). The toggles always
## show what the sim says (CheatModel.read, asked again on each refresh), never a copy kept here: a cheat asked
## for applies at the sim's next request, and cheats_changed brings the new state.
## `backend` is a LiveSession (or a test stand-in with the same methods); null = no live game.
## A pad works the page through KeyMenu (pad_move / pad_adjust / pad_press): the D-pad or stick picks a control
## (highlighted), left / right change a picker or a number, A presses or flips it, or puts the focus in a text
## field (Y then opens the on-screen keys). The VR panel's laser clicks it, and its stick does what the D-pad does.

const WARN := Color(1.0, 0.75, 0.3)
const PICKED := Color(1.0, 0.8, 0.35)
## The wind choices: label, m/s (LiveSession.WIND_GAME: the game decides).
const WINDS := [["Wind as the game decides", -1.0], ["Calm", 0.0], ["Breeze", 5.0], ["Strong wind", 15.0]]
const WEATHER_GAME := "Weather as the game decides"

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
## () -> int: teleports to the square at the screen's centre (main.gd's _teleport), the op id or 0. Main sets it.
var teleport := Callable()
var teleport_button: Button
## The weather cheat: CDDA's weather types (LiveSession.weather_types), the wind, and the button that sends both.
var weather_pick: OptionButton
var wind_pick: OptionButton
var weather_button: Button
## The pad's pick: an index into pad_controls(), -1 = none yet.
var pick := -1
var _marked: Control
var _weather_ids: Array = []   # the types shown, to rebuild the list only when it changed
var _weather_held := "\n"     # the sim's weather when last shown ("\n": not yet)
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
	teleport_button = _button("Teleport to the crosshair", teleport_here)
	teleport_button.name = "Teleport"
	row.add_child(teleport_button)
	add_child(row)
	_build_weather()
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
	refresh_weather()
	teleport_button.disabled = not (_has("can_teleport") and backend.can_teleport())
	teleport_button.tooltip_text = ("Moves you to the square at the screen's centre, through walls and between floors. "
			+ "Key: %s (the square under the crosshair).%s") % [InputActions.key_of(&"cheat_teleport"),
			" Needs cheats allowed and a bridge that has it." if teleport_button.disabled else ""]
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


func teleport_here() -> void:
	if teleport_button.disabled:
		_say("Teleport: needs a running game with cheats allowed.", true)
		return
	var id: int = teleport.call() if teleport.is_valid() else 0
	if id < 1:
		_say("Teleport: not sent. Point the crosshair at a square in the loaded area.", true)
		return
	_sent("Teleport", id)


func _build_weather() -> void:
	var r := HBoxContainer.new()
	r.name = "Weather"
	weather_pick = OptionButton.new()
	weather_pick.focus_mode = Control.FOCUS_NONE
	weather_pick.fit_to_longest_item = false
	weather_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	weather_pick.add_item(WEATHER_GAME)
	weather_pick.set_item_metadata(0, "")
	r.add_child(weather_pick)
	wind_pick = OptionButton.new()
	wind_pick.focus_mode = Control.FOCUS_NONE
	for w: Array in WINDS:
		wind_pick.add_item(w[0])
	r.add_child(wind_pick)
	weather_button = _button("Set weather", set_weather)
	weather_button.tooltip_text = "Holds the weather and the wind you picked until you hand them back to the game."
	r.add_child(weather_button)
	add_child(r)


## The weather row: CDDA's types, the list rebuilt only when it changed; the cheat's weather picked when the sim's
## changed since it was last shown (a pick not sent yet stays otherwise); greyed out while cheats aren't allowed.
func refresh_weather() -> void:
	var ok: bool = _has("can_set_weather") and backend.can_set_weather()
	var types: Array = backend.weather_types() if ok and _has("weather_types") else []
	var ids: Array = types.map(func(t: Dictionary) -> String: return t["id"])
	var held: String = backend.cheat_weather() if ok and _has("cheat_weather") else ""
	if ids != _weather_ids:
		_weather_ids = ids
		weather_pick.clear()
		weather_pick.add_item(WEATHER_GAME)
		weather_pick.set_item_metadata(0, "")
		for t: Dictionary in types:
			weather_pick.add_item(t["name"])
			weather_pick.set_item_metadata(weather_pick.item_count - 1, t["id"])
		_weather_held = "\n"
	if held != _weather_held:
		_weather_held = held
		weather_pick.select(ids.find(held) + 1)   # not in the list, or "": as the game decides
	for c: BaseButton in [weather_pick, wind_pick, weather_button]:
		c.disabled = not ok


func set_weather() -> void:
	if weather_button.disabled:
		_say("Weather: needs a running game with cheats allowed.", true)
		return
	var i := weather_pick.selected
	var id: Variant = weather_pick.get_item_metadata(i) if i >= 0 else ""
	var w := wind_pick.selected
	var wind: float = WINDS[w][1] if w >= 0 and w < WINDS.size() else LiveSession.WIND_GAME
	var what := "Weather %s%s" % [weather_pick.get_item_text(i) if i > 0 else "back to the game",
			", %s" % str(WINDS[w][0]).to_lower() if wind >= 0.0 else ""]
	_sent(what, backend.cheat_set_weather(id, wind) if id is String and _has("cheat_set_weather") else 0)


## The controls a pad reaches, in reading order: the visible buttons, pickers, number boxes and text fields.
func pad_controls() -> Array[Control]:
	var out: Array[Control] = []
	_reachable(self, out)
	return out


## Moves the pad's pick `d` controls on, wrapping; the first move picks the first. A text field of the page that
## has the focus (picked with A, or clicked) is where it moves from, and loses the focus (the keys follow it).
func pad_move(d: int) -> void:
	var cs := pad_controls()
	var f := focused_field()
	if f != null:
		f.release_focus()
		if cs.has(f):
			pick = cs.find(f)
	if cs.is_empty():
		return
	pick = 0 if pick < 0 or pick >= cs.size() else wrapi(pick + signi(d), 0, cs.size())
	_mark(cs[pick])


## Left / right: the next or previous choice of a picked picker, a number box's step; elsewhere a move.
func pad_adjust(d: int) -> void:
	var c := _picked(pad_controls())
	if c is OptionButton and not (c as OptionButton).disabled and (c as OptionButton).item_count > 0:
		var ob := c as OptionButton
		ob.select(wrapi(ob.selected + signi(d), 0, ob.item_count))
		ob.item_selected.emit(ob.selected)
	elif c is SpinBox and (c as SpinBox).editable:
		var sb := c as SpinBox
		sb.value += signi(d) * maxf(sb.step, 1.0)
	else:
		pad_move(d)


## A: presses the picked button or flips a toggle (a picker: its next choice), or puts the focus in a text field.
## A text field focused by a click (not the pick) is picked first: A presses nothing else while the keys type there.
func pad_press() -> void:
	var cs := pad_controls()
	var c := _picked(cs)
	var f := focused_field()
	if f != null and f != c:
		pick = cs.find(f)
		_mark(f)
		return
	if c is OptionButton:
		pad_adjust(1)
	elif c is BaseButton and not (c as BaseButton).disabled:
		var b := c as BaseButton
		if b.toggle_mode:
			b.button_pressed = not b.button_pressed
		else:
			b.pressed.emit()
	elif c is LineEdit and (c as LineEdit).editable:
		c.grab_focus()
	elif c == null:
		pad_move(1)


## The page's text field that has the keyboard focus, or null.
func focused_field() -> LineEdit:
	var vp: Viewport = get_viewport() if is_inside_tree() else null
	var f: LineEdit = vp.gui_get_focus_owner() as LineEdit if vp != null else null
	return f if f != null and is_ancestor_of(f) else null


func _picked(cs: Array[Control]) -> Control:
	return cs[pick] if pick >= 0 and pick < cs.size() else null


func _mark(c: Control) -> void:
	if _marked != null and is_instance_valid(_marked):
		_marked.modulate = Color.WHITE
	_marked = c
	if c != null:
		c.modulate = PICKED
		var sc := get_parent() as ScrollContainer   # KeyMenu's: the pick scrolls into view
		if sc != null and sc.is_inside_tree():
			sc.ensure_control_visible(c)


static func _reachable(n: Node, out: Array[Control]) -> void:
	for c: Node in n.get_children():
		if not c is Control or not (c as Control).visible:
			continue
		if c is BaseButton or c is SpinBox or c is LineEdit:
			out.append(c)
		else:
			_reachable(c, out)


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
	hour.custom_minimum_size.x = 130   # room for "Time 23 :00"
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
		_say("%s: not sent (no game, or too many waiting)." % what, true)
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
