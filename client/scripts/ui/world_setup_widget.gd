class_name WorldSetupRequestWidget
extends RequestWidget
## `world_setup` requests: CDDA's "Create World" drawn by the client over a `WorldSetup` model. Tab World: the
## sliders (city size, spawns, ...) and the other world settings by type; tab Mods: tick mods (dependencies
## follow, a description shows on click). Create sends the choices as JSON in `text`; Esc or Cancel ends the
## new game. The sim's complaint about the last answer is in `status`. Ctrl+Enter creates.

const PANE_HEIGHT := 400.0
const BAD := Color(1.0, 0.45, 0.4)

var model: WorldSetup
var tabs: TabContainer
var status_label: Label
var create_button: Button
var _mod_list: ItemList
var _mod_ids: Array[String] = []
var _mod_detail: RichTextLabel
var _slider_notes := {}   # slider id -> Label


func setup(req: Dictionary) -> void:
	super(req)
	custom_minimum_size = Vector2(760, 0)
	model = WorldSetup.parse(str_of(req, "text", 4_000_000))
	add_header({"title": str_of(req, "title", 200)})
	if not model.ok:
		add_rich("<color_light_red>Can't read the world settings: %s</color>" % model.error)
		var b := HBoxContainer.new()
		add_child(b)
		add_button("Cancel (Esc)", cancel, b)
		return
	tabs = TabContainer.new()
	tabs.custom_minimum_size.y = PANE_HEIGHT
	tabs.focus_mode = Control.FOCUS_NONE
	add_child(tabs)
	_build_world_tab()
	_build_mods_tab()
	status_label = Label.new()
	status_label.add_theme_color_override("font_color", BAD)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status_label)
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_END
	add_child(bar)
	if allow_cancel:
		add_button("Cancel (Esc)", cancel, bar)
	create_button = add_button("Create world (Ctrl+Enter)", create, bar)
	add_hint("Hover a setting for its description.  Double-click a mod to tick it.")
	var sim_status := str_of(req, "status", 400)
	refresh()
	if not sim_status.is_empty():
		status_label.text = "The game refused: " + sim_status


func _build_world_tab() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "World"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	for s in model.sliders:
		var id: String = s["id"]
		_label(grid, s["name"], "")
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(col)
		var pick := OptionButton.new()
		pick.focus_mode = Control.FOCUS_NONE
		for l: Dictionary in s["levels"]:
			pick.add_item(CddaText.plain(l["name"]))
		pick.selected = model.levels[id]
		pick.item_selected.connect(func(i: int) -> void:
			model.set_level(id, i)
			refresh())
		col.add_child(pick)
		var note := Label.new()
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_font_size_override("font_size", 12)
		note.add_theme_color_override("font_color", HINT_COLOR)
		col.add_child(note)
		_slider_notes[id] = note
	for o in model.options:
		_label(grid, o["name"] if not (o["name"] as String).is_empty() else o["id"], CddaText.plain(o["tooltip"]))
		grid.add_child(_editor(o))


func _editor(o: Dictionary) -> Control:
	var id: String = o["id"]
	match o["type"]:
		"bool":
			var c := CheckBox.new()
			c.button_pressed = o["value"]
			c.focus_mode = Control.FOCUS_NONE
			c.toggled.connect(func(on: bool) -> void: set_option(id, on))
			return c
		"int", "float":
			var sb := SpinBox.new()
			sb.min_value = o["min"]
			sb.max_value = o["max"]
			sb.step = o["step"]
			sb.value = o["value"]
			sb.value_changed.connect(func(v: float) -> void: set_option(id, int(v) if o["type"] == "int" else v))
			return sb
		"int_map", "string_select":
			var ob := OptionButton.new()
			ob.focus_mode = Control.FOCUS_NONE
			var i := 0
			for c: Array in o["choices"]:
				ob.add_item(c[1] if not (c[1] as String).is_empty() else str(c[0]))
				if c[0] == o["value"] or (o["type"] == "int_map" and int(c[0]) == int(o["value"])):
					ob.selected = i
				i += 1
			ob.item_selected.connect(func(k: int) -> void: set_option(id, o["choices"][k][0]))
			return ob
	var le := LineEdit.new()
	le.max_length = o.get("max_length", 64)
	le.text = o["value"]
	le.text_changed.connect(func(t: String) -> void: set_option(id, t))
	return le


func _build_mods_tab() -> void:
	var row := HBoxContainer.new()
	row.name = "Mods"
	tabs.add_child(row)
	_mod_list = ItemList.new()
	_mod_list.custom_minimum_size.x = 330
	_mod_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_mod_list.focus_mode = Control.FOCUS_NONE
	_mod_list.item_selected.connect(_show_mod)
	_mod_list.item_activated.connect(func(i: int) -> void: pick_mod(i))
	row.add_child(_mod_list)
	_mod_detail = RichTextLabel.new()
	_mod_detail.bbcode_enabled = true
	_mod_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mod_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(_mod_detail)


func _label(parent: Control, text: String, tip: String) -> void:
	var l := Label.new()
	l.text = CddaText.plain(text)
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.custom_minimum_size.x = 260
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)


# --- Actions (also called by tests) --------------------------------------------------------------------

func set_option(id: String, v: Variant) -> bool:
	var ok := model.set_value(id, v)
	status_label.text = "" if ok else "That value doesn't fit."
	return ok


## Ticks or unticks the mod at list row `i`; false if it can't be ticked (a conflict).
func pick_mod(i: int) -> bool:
	if i < 0 or i >= _mod_ids.size():
		return false
	var id := _mod_ids[i]
	var c := model.conflict_of(id)
	if not model.toggle_mod(id):
		status_label.text = "%s conflicts with %s" % [model.mods[id]["name"], model.mods[c]["name"] if model.mods.has(c) else c]
		return false
	status_label.text = ""
	refresh()
	_mod_list.select(i)
	_show_mod(i)
	return true


func create() -> bool:
	var why := model.problem()
	var text := model.answer_json() if why.is_empty() else ""
	if why.is_empty() and text.is_empty():
		why = "too many choices to send"
	if not why.is_empty():
		status_label.text = why
		return false
	send({"text": text})
	return true


func handle_input(event: InputEvent) -> bool:
	var key := key_of(event)
	if key == KEY_ESCAPE:
		return cancel()
	if model == null or not model.ok:
		return false
	var k := event as InputEventKey
	if k != null and k.ctrl_pressed and (key == KEY_ENTER or key == KEY_KP_ENTER):
		return create()
	if k != null and k.ctrl_pressed and key == KEY_TAB:
		tabs.current_tab = wrapi(tabs.current_tab + 1, 0, tabs.get_tab_count())
		return true
	return false


func refresh() -> void:
	for s in model.sliders:
		var lv: Dictionary = s["levels"][model.levels[s["id"]]]
		(_slider_notes[s["id"]] as Label).text = CddaText.plain(lv["description"])
	var keep := _mod_list.get_selected_items()
	_mod_list.clear()
	_mod_ids.clear()
	var ids := model.mod_order.duplicate()
	ids.sort_custom(func(a: String, b: String) -> bool:
		var ma: Dictionary = model.mods[a]
		var mb: Dictionary = model.mods[b]
		if ma["core"] != mb["core"]:
			return ma["core"]
		return [ma["category"], ma["name"]] < [mb["category"], mb["name"]])
	for id: String in ids:
		var m: Dictionary = model.mods[id]
		var on := model.picked_mods.has(id)
		var i := _mod_list.add_item("%s %s%s" % ["[x]" if on else "[ ]", CddaText.plain(m["name"]),
				"  (core)" if m["core"] else ""])
		if not on and not model.conflict_of(id).is_empty():
			_mod_list.set_item_custom_fg_color(i, Color(0.55, 0.55, 0.55))
		_mod_ids.append(id)
	if not keep.is_empty() and keep[0] < _mod_list.item_count:
		_mod_list.select(keep[0])
	create_button.disabled = not model.problem().is_empty()
	if not model.problem().is_empty():
		status_label.text = model.problem()


func _show_mod(i: int) -> void:
	if i < 0 or i >= _mod_ids.size():
		return
	var m: Dictionary = model.mods[_mod_ids[i]]
	var deps := PackedStringArray()
	for d: String in m["dependencies"]:
		deps.append(model.mods[d]["name"] if model.mods.has(d) else d)
	_mod_detail.text = "[b]%s[/b]  [i]%s[/i]\n\n%s%s" % [CddaText.to_bbcode(m["name"]), CddaText.to_bbcode(m["category"]),
			CddaText.to_bbcode(m["description"]), ("\n\nNeeds: " + ", ".join(deps)) if not deps.is_empty() else ""]
