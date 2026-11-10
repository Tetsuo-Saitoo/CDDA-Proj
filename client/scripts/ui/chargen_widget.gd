class_name ChargenRequestWidget
extends RequestWidget
## `chargen` requests: CDDA's character creation drawn by the client. Tabs Scenario, Profession, Background,
## Stats, Traits, Skills, Description over a `Chargen` model built from the request's catalog (`text`); the
## sim's complaint about the last answer is in `status`. Start sends the choices as JSON in `text`; Esc (or
## Cancel) cancels, which ends the new game. Plain Controls only, so it can later sit on a world-space panel.
## Keys: Ctrl+Tab / Ctrl+Shift+Tab switch tabs, Ctrl+Enter starts.

const TABS := ["Scenario", "Profession", "Background", "Stats", "Traits", "Skills", "Description"]
const LIST_WIDTH := 330.0
const PANE_HEIGHT := 380.0
const BAD := Color(1.0, 0.45, 0.4)

var model: Chargen
var tabs: TabContainer
var points_label: Label
var status_label: Label
var start_button: Button
var _lists := {}            # tab name -> ItemList
var _list_ids := {}         # tab name -> Array of ids in list order
var _details := {}          # tab name -> RichTextLabel
var _stat_values := {}      # stat key -> Label
var _skill_values := {}     # skill id -> Label
var _name_edit: LineEdit
var _gender: OptionButton
var _age: SpinBox
var _height: SpinBox
var _summary: RichTextLabel
var _templates: OptionButton
var _save_edit: LineEdit
var _rng := RandomNumberGenerator.new()


func setup(req: Dictionary) -> void:
	super(req)
	custom_minimum_size = Vector2(760, 0)
	model = Chargen.parse(str_of(req, "text", 4_000_000))
	var title := Label.new()
	title.text = "New character"
	title.add_theme_font_size_override("font_size", 20)
	add_child(title)
	if not model.ok:
		add_rich("<color_light_red>Can't read the character catalog: %s</color>" % model.error)
		var bar := HBoxContainer.new()
		add_child(bar)
		add_button("Cancel (Esc)", cancel, bar)
		return
	if not model.templates.is_empty():
		var trow := HBoxContainer.new()
		add_child(trow)
		var tl := Label.new()
		tl.text = "Template:"
		trow.add_child(tl)
		_templates = OptionButton.new()
		_templates.focus_mode = Control.FOCUS_NONE
		for t in model.templates:
			_templates.add_item(t)
		trow.add_child(_templates)
		add_button("Start from template", func() -> void: start_template(_templates.selected), trow)
	tabs = TabContainer.new()
	tabs.custom_minimum_size.y = PANE_HEIGHT
	tabs.focus_mode = Control.FOCUS_NONE
	add_child(tabs)
	_build_list_tab("Scenario")
	_build_list_tab("Profession")
	_build_list_tab("Background")
	_build_stats_tab()
	_build_list_tab("Traits")
	_build_skills_tab()
	_build_description_tab()
	points_label = Label.new()
	add_child(points_label)
	status_label = Label.new()
	status_label.add_theme_color_override("font_color", BAD)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status_label)
	var sim_status := str_of(req, "status", 400)
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_END
	add_child(bar)
	add_button("Random", randomize_character, bar)
	if allow_cancel:
		add_button("Cancel (Esc)", cancel, bar)
	start_button = add_button("Start (Ctrl+Enter)", start, bar)
	add_hint("Click to see, double-click (or Toggle) to pick.  Ctrl+Tab switches tabs.")
	refresh_all()
	if not sim_status.is_empty():
		status_label.text = "The game refused: " + sim_status


# --- Building ------------------------------------------------------------------------------------------

func _build_list_tab(tab: String) -> void:
	var row := HBoxContainer.new()
	row.name = tab
	tabs.add_child(row)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = LIST_WIDTH
	row.add_child(left)
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.focus_mode = Control.FOCUS_NONE
	list.item_selected.connect(func(i: int) -> void: _show_detail(tab, i))
	list.item_activated.connect(func(i: int) -> void: pick(tab, i))
	left.add_child(list)
	if tab == "Background" or tab == "Traits":
		add_button("Toggle", func() -> void:
			var sel := list.get_selected_items()
			if not sel.is_empty():
				pick(tab, sel[0]), left)
	var detail := RichTextLabel.new()
	detail.bbcode_enabled = true
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(detail)
	_lists[tab] = list
	_details[tab] = detail


func _build_stats_tab() -> void:
	var box := VBoxContainer.new()
	box.name = "Stats"
	tabs.add_child(box)
	for k: String in Chargen.STATS:
		var row := HBoxContainer.new()
		box.add_child(row)
		var l := Label.new()
		l.text = Chargen.STAT_NAMES[k]
		l.custom_minimum_size.x = 140
		row.add_child(l)
		add_button(" - ", func() -> void: change_stat(k, -1), row)
		var v := Label.new()
		v.custom_minimum_size.x = 40
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(v)
		add_button(" + ", func() -> void: change_stat(k, 1), row)
		_stat_values[k] = v
	var note := Label.new()
	note.text = "Each point above %d costs double." % model.high_stat
	box.add_child(note)


func _build_skills_tab() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Skills"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	for s in model.skills:
		var id: String = s["id"]
		var row := HBoxContainer.new()
		row.tooltip_text = CddaText.plain(s["description"])
		box.add_child(row)
		var l := Label.new()
		l.text = s["name"]
		l.custom_minimum_size.x = 220
		row.add_child(l)
		add_button(" - ", func() -> void: change_skill(id, -1), row)
		var v := Label.new()
		v.custom_minimum_size.x = 40
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(v)
		add_button(" + ", func() -> void: change_skill(id, 1), row)
		_skill_values[id] = v


func _build_description_tab() -> void:
	var box := VBoxContainer.new()
	box.name = "Description"
	tabs.add_child(box)
	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	_label(grid, "Name")
	_name_edit = LineEdit.new()
	_name_edit.max_length = model.max_name
	_name_edit.placeholder_text = "(random)"
	_name_edit.custom_minimum_size.x = 260
	_name_edit.text_changed.connect(func(t: String) -> void:
		model.set_name(t)
		refresh_points())
	grid.add_child(_name_edit)
	_label(grid, "Gender")
	_gender = OptionButton.new()
	_gender.add_item("Male")
	_gender.add_item("Female")
	_gender.focus_mode = Control.FOCUS_NONE
	_gender.item_selected.connect(func(i: int) -> void:
		model.male = i == 0
		refresh_all())
	grid.add_child(_gender)
	_label(grid, "Age")
	_age = _spin(grid, model.min_age, model.max_age, func(v: float) -> void: model.set_age(int(v)))
	_label(grid, "Height (cm)")
	_height = _spin(grid, model.min_height, model.max_height, func(v: float) -> void: model.set_height(int(v)))
	_label(grid, "Save as template")
	_save_edit = LineEdit.new()
	_save_edit.max_length = 64
	_save_edit.placeholder_text = "(don't save)"
	_save_edit.text_changed.connect(func(t: String) -> void:
		model.save_template = t.strip_edges()
		refresh_points())
	grid.add_child(_save_edit)
	_summary = RichTextLabel.new()
	_summary.bbcode_enabled = true
	_summary.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_summary)


func _label(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	parent.add_child(l)


func _spin(parent: Control, lo: int, hi: int, on_change: Callable) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 1
	s.value_changed.connect(on_change)
	parent.add_child(s)
	return s


# --- Actions (also called by tests) --------------------------------------------------------------------

## Picks entry `i` of a list tab: scenario/profession select, background/trait toggle.
func pick(tab: String, i: int) -> bool:
	var ids: Array = _list_ids.get(tab, [])
	if i < 0 or i >= ids.size():
		return false
	var id: String = ids[i]
	var changed := false
	match tab:
		"Scenario":
			changed = model.set_scenario(id)
		"Profession":
			changed = model.set_profession(id)
		"Background":
			changed = model.toggle_background(id)
		"Traits":
			changed = model.toggle_trait(id)
			if not changed:
				status_label.text = model.trait_blocker(id)
	if changed:
		status_label.text = ""
		refresh_all()
		(_lists[tab] as ItemList).select(i)
		_show_detail(tab, i)
	return changed


func change_stat(key: String, delta: int) -> void:
	if model.set_stat(key, int(model.stats[key]) + delta):
		refresh_all()


func change_skill(id: String, delta: int) -> void:
	if model.set_skill(id, int(model.skill_levels.get(id, 0)) + delta):
		refresh_all()


func randomize_character() -> void:
	model.randomize_choices(_rng)
	refresh_all()


func start() -> bool:
	var why := model.problem()
	var text := model.answer_json() if why.is_empty() else ""
	if why.is_empty() and text.is_empty():
		why = "too many choices to send"
	if not why.is_empty():
		status_label.text = why
		return false
	send({"text": text})
	return true


## Starts with template number `i` (name from the Name field, if any); true if sent.
func start_template(i: int) -> bool:
	if i < 0 or i >= model.templates.size():
		return false
	var text := model.template_answer(model.templates[i])
	if text.is_empty():
		return false
	send({"text": text})
	return true


func handle_input(event: InputEvent) -> bool:
	if model == null or not model.ok:
		if key_of(event) == KEY_ESCAPE:
			return cancel()
		return false
	var k := event as InputEventKey
	var key := key_of(event)
	if key == KEY_ESCAPE:
		return cancel()
	if k != null and k.ctrl_pressed and (key == KEY_ENTER or key == KEY_KP_ENTER):
		return start()
	if k != null and k.ctrl_pressed and key == KEY_TAB:
		tabs.current_tab = wrapi(tabs.current_tab + (-1 if k.shift_pressed else 1), 0, tabs.get_tab_count())
		return true
	return false


# --- Showing -------------------------------------------------------------------------------------------

func refresh_all() -> void:
	_fill("Scenario", model.scenarios, func(e: Dictionary) -> bool: return e["id"] == model.scenario)
	_fill("Profession", model.allowed_professions(),
			func(e: Dictionary) -> bool: return e["id"] == model.profession)
	_fill("Background", model.allowed_backgrounds(),
			func(e: Dictionary) -> bool: return model.picked_backgrounds.has(e["id"]))
	var locked := model.locked_traits()
	_fill("Traits", model.listed_traits(),
			func(e: Dictionary) -> bool: return model.picked_traits.has(e["id"]) or locked.has(e["id"]))
	for k: String in _stat_values:
		(_stat_values[k] as Label).text = str(model.stats[k])
	for id: String in _skill_values:
		(_skill_values[id] as Label).text = str(model.skill_levels.get(id, 0))
	if _name_edit != null and _name_edit.text.strip_edges() != model.char_name:
		_name_edit.text = model.char_name
	if _gender != null:
		_gender.selected = 0 if model.male else 1
	if _age != null:
		_age.set_value_no_signal(model.age)
		_height.set_value_no_signal(model.height)
	refresh_points()


func refresh_points() -> void:
	if points_label == null:
		return
	if model.enforce_points:
		points_label.text = "Points left: %d   (stats %d, traits %d, skills %d)" % [model.points_left(),
				model.stat_pool - model.stat_points_used(), model.trait_pool - model.trait_points_used(),
				model.skill_pool - model.skill_points_used()]
	else:
		points_label.text = "Points: %d   (no limit: story teller pool)" % -model.points_left()
	var why := model.problem()
	start_button.disabled = not why.is_empty()
	if _summary != null:
		var traits := PackedStringArray()
		for id in model.locked_traits() + model.picked_traits:
			traits.append(model.traits[id]["name"] if model.traits.has(id) else id)
		var bgs := PackedStringArray()
		for b in model.picked_backgrounds:
			bgs.append(model.profession_name(b))
		var sc: Dictionary = model.scen()
		_summary.text = "[b]%s[/b], %s\nScenario: %s\nBackgrounds: %s\nTraits: %s" % [
				model.char_name if not model.char_name.is_empty() else "(random name)",
				model.profession_name(model.profession), sc.get("name", ""),
				", ".join(bgs) if not bgs.is_empty() else "-", ", ".join(traits) if not traits.is_empty() else "-"]


func _fill(tab: String, entries: Array, chosen: Callable) -> void:
	var list: ItemList = _lists[tab]
	var keep := list.get_selected_items()
	list.clear()
	var ids := []
	for e: Dictionary in entries:
		var on: bool = chosen.call(e)
		var name: String = model.profession_name(e["id"]) if tab in ["Profession", "Background"] else e["name"]
		var label := "%s %s  (%d)" % ["[x]" if on else "[ ]", CddaText.plain(name), e["points"]]
		var i := list.add_item(label)
		if tab == "Traits" and not on and not model.trait_blocker(e["id"]).is_empty():
			list.set_item_custom_fg_color(i, Color(0.55, 0.55, 0.55))
		ids.append(e["id"])
	_list_ids[tab] = ids
	if not keep.is_empty() and keep[0] < list.item_count:
		list.select(keep[0])


func _show_detail(tab: String, i: int) -> void:
	var ids: Array = _list_ids.get(tab, [])
	if i < 0 or i >= ids.size():
		return
	var id: String = ids[i]
	var e: Dictionary = {}
	match tab:
		"Scenario":
			var s: Variant = model.scenario_entry(id)
			e = s if s != null else {}
		"Profession":
			e = model.professions.get(id, {})
		"Background":
			e = model.backgrounds.get(id, {})
		"Traits":
			e = model.traits.get(id, {})
	if e.is_empty():
		return
	var text := "[b]%s[/b]  (%d points)\n\n%s" % [CddaText.to_bbcode(model.profession_name(id) if tab in
			["Profession", "Background"] else e["name"]), e["points"], CddaText.to_bbcode(e["description"])]
	if e.has("skills") and not (e["skills"] as Dictionary).is_empty():
		var parts := PackedStringArray()
		for s: String in e["skills"]:
			parts.append("%s %d" % [_skill_name(s), e["skills"][s]])
		text += "\n\nSkills: " + ", ".join(parts)
	if tab == "Traits":
		var why := model.trait_blocker(id)
		if not why.is_empty() and not model.picked_traits.has(id):
			text += "\n\n[color=#ff7766]%s[/color]" % why
	(_details[tab] as RichTextLabel).text = text


func _skill_name(id: String) -> String:
	for s in model.skills:
		if s["id"] == id:
			return s["name"]
	return id
