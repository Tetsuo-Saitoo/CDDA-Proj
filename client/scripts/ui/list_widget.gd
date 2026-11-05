class_name ListRequestWidget
extends RequestWidget
## `menu`, `item_select`, `item_multi` and `key` requests: a list for mouse and keyboard, with a filter field
## for long lists. Up/Down/PgUp/PgDn move, Enter picks, Esc clears the filter or cancels, 1-9 pick in short
## lists (no filter). Mouse: hover shows the description, click picks. Disabled entries show but can't be
## picked. item_multi: click, Tab or Space (filter empty) ticks an entry, Left/Right (Shift: 10) or the Count
## box set its count (0 = all), Enter takes the ticked ones (or the current one).
## Answers: menu / item_select `entry`, key `action`, item_multi `picks` [[entry, count], ...].

const FILTER_MIN := 10
const MAX_ROWS := 200      # rows built at once; the filter reaches the rest
const PAGE := 10
const ROW_H := 28.0
const MAX_COUNT := 1000000

var kind := ""
var items: Array = []        # {id, label, enabled, description, plain}; for `key`, id = index into actions
var shown: Array[int] = []   # index into items for each row
var selected := -1           # row
var rows: Array[Button] = []
var picks := {}              # item_multi: entry id -> count (0 = all)
var filter_edit: LineEdit
var count_spin: SpinBox
var _actions := PackedStringArray()
var _list: VBoxContainer
var _scroll: ScrollContainer
var _desc: RichTextLabel
var _more: Label


func setup(req: Dictionary) -> void:
	super(req)
	kind = str_of(req, "kind")
	if kind == "key":
		_actions = actions_of(req)
		for i in _actions.size():
			items.append({"id": i, "label": action_label(_actions[i]), "enabled": true, "description": ""})
	else:
		items = entries_of(req)
	var has_desc := false
	for it: Dictionary in items:
		it["plain"] = CddaText.plain(it["label"]).replace("\n", " ")
		if kind == "key":
			it["plain"] += " " + _actions[it["id"]]
		has_desc = has_desc or not CddaText.plain(it["description"]).strip_edges().is_empty()
	add_header(req)
	if items.size() >= FILTER_MIN:
		filter_edit = LineEdit.new()
		filter_edit.placeholder_text = "Type to filter"
		filter_edit.clear_button_enabled = true
		filter_edit.text_changed.connect(set_filter)
		add_child(filter_edit)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size.y = clampf(items.size() * (ROW_H + 1.0), ROW_H, 380.0)
	add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 1)
	_scroll.add_child(_list)
	_more = Label.new()
	_more.add_theme_color_override("font_color", HINT_COLOR)
	add_child(_more)
	if has_desc:
		_desc = add_rich("")
		_desc.custom_minimum_size.y = 44
		_desc.add_theme_color_override("default_color", Color(0.78, 0.78, 0.72))
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_END
	add_child(bar)
	if kind == "item_multi":
		var l := Label.new()
		l.text = "Count"
		bar.add_child(l)
		count_spin = SpinBox.new()
		count_spin.min_value = 0
		count_spin.max_value = MAX_COUNT
		count_spin.rounded = true
		count_spin.tooltip_text = "0 = all"
		count_spin.value_changed.connect(_on_count_changed)
		bar.add_child(count_spin)
		add_button("All", toggle_all, bar)
		add_button("Take (Enter)", confirm, bar)
	if allow_cancel:
		add_button("Cancel (Esc)", cancel, bar)
	var keys := "Up/Down move  "
	if kind == "item_multi":
		keys += "Tab/Space tick  Left/Right count (0 = all)  Enter take  "
	else:
		keys += "Enter pick  " + ("" if filter_edit != null else "1-9 pick  ")
	if filter_edit != null:
		keys += "type to filter  "
	add_hint(keys + ("Esc cancel" if allow_cancel else ""))
	set_filter("")
	if filter_edit != null:
		focus_later(filter_edit)


## Shows the entries whose plain label contains `text` (any case).
func set_filter(text: String) -> void:
	if filter_edit != null and filter_edit.text != text:
		filter_edit.text = text
	var f := text.strip_edges().to_lower()
	shown.clear()
	var total := 0
	for i in items.size():
		if f.is_empty() or (items[i]["plain"] as String).to_lower().contains(f):
			total += 1
			if shown.size() < MAX_ROWS:
				shown.append(i)
	_rebuild_rows()
	_more.text = "" if total == shown.size() else "... %d more: type to filter" % (total - shown.size())
	_more.visible = not _more.text.is_empty()
	if items.is_empty():
		_more.text = "(nothing to choose)"
		_more.visible = true
	elif shown.is_empty():
		_more.text = "(no match)"
		_more.visible = true
	selected = -1
	var first := 0
	for row in shown.size():
		if items[shown[row]]["enabled"]:
			first = row
			break
	select(first)


## The entry shown in `row`.
func item_at(row: int) -> Dictionary:
	return items[shown[row]] if row >= 0 and row < shown.size() else {}


func select(row: int) -> void:
	if row < 0 or row >= rows.size():
		_show_desc()
		return
	if selected >= 0 and selected < rows.size():
		mark(rows[selected], false)
	selected = row
	mark(rows[row], true)
	_ensure_visible.call_deferred(rows[row])
	_show_desc()
	_sync_count()


func move(delta: int) -> void:
	if not rows.is_empty():
		select(clampi(selected + delta, 0, rows.size() - 1))


## Click, Enter or a number key on `row`: picks it (item_multi: ticks it).
func activate(row: int) -> void:
	var it := item_at(row)
	if it.is_empty():
		return
	select(row)
	if not it["enabled"]:
		return
	if kind == "item_multi":
		toggle(row)
	elif kind == "key":
		send({"action": _actions[it["id"]]})
	else:
		send({"entry": it["id"]})


func toggle(row: int) -> void:
	var it := item_at(row)
	if it.is_empty() or not it["enabled"] or kind != "item_multi":
		return
	if picks.has(it["id"]):
		picks.erase(it["id"])
	else:
		picks[it["id"]] = 0
	_update_row(row)
	_sync_count()


## item_multi: changes the current entry's count (0 = all) and ticks it.
func change_count(delta: int) -> void:
	var it := item_at(selected)
	if it.is_empty() or not it["enabled"] or kind != "item_multi" or (delta < 0 and not picks.has(it["id"])):
		return
	picks[it["id"]] = clampi(int(picks.get(it["id"], 0)) + delta, 0, MAX_COUNT)
	_update_row(selected)
	_sync_count()


## item_multi: ticks every shown entry, or unticks them if all are ticked.
func toggle_all() -> void:
	var all_on := true
	for i in shown:
		if items[i]["enabled"] and not picks.has(items[i]["id"]):
			all_on = false
	for row in shown.size():
		var it: Dictionary = items[shown[row]]
		if it["enabled"]:
			if all_on:
				picks.erase(it["id"])
			elif not picks.has(it["id"]):
				picks[it["id"]] = 0
			_update_row(row)
	_sync_count()


## item_multi: sends the ticked entries, or the current one if none is ticked.
func confirm() -> void:
	if kind != "item_multi":
		activate(selected)
		return
	var out := []
	for it: Dictionary in items:
		if picks.has(it["id"]) and out.size() < MAX_PICKS:
			out.append([it["id"], picks[it["id"]]])
			picks.erase(it["id"])   # entries with the same id go once
	if out.is_empty():
		var it := item_at(selected)
		if it.is_empty() or not it["enabled"]:
			return
		out.append([it["id"], 0])
	send({"picks": out})


func handle_input(event: InputEvent) -> bool:
	var key := key_of(event, true)
	if key == KEY_NONE:
		return false
	var k := event as InputEventKey
	var multi := kind == "item_multi"
	match key:
		KEY_UP, KEY_KP_8:
			move(-1)
		KEY_DOWN, KEY_KP_2:
			move(1)
		KEY_PAGEUP, KEY_KP_9:
			move(-PAGE)
		KEY_PAGEDOWN, KEY_KP_3:
			move(PAGE)
		KEY_ENTER, KEY_KP_ENTER:
			if not k.echo:
				confirm()
		KEY_ESCAPE:
			if not k.echo:
				if filter_edit != null and not filter_edit.text.is_empty():
					set_filter("")
				else:
					cancel()
		KEY_TAB:
			if not multi:
				return false
			if not k.echo:
				toggle(selected)
		KEY_SPACE:
			if not multi or (filter_edit != null and not filter_edit.text.is_empty()):
				return false   # a space in the filter
			if not k.echo:
				toggle(selected)
		KEY_LEFT, KEY_RIGHT:
			if not multi:
				return false   # caret in the filter
			change_count((10 if k.shift_pressed else 1) * (1 if key == KEY_RIGHT else -1))
		_:
			if filter_edit == null and key >= KEY_1 and key <= KEY_9 and not k.echo:
				activate(key - KEY_1)
				return true
			return false
	return true


func _rebuild_rows() -> void:
	for r in rows:
		_list.remove_child(r)
		r.queue_free()
	rows.clear()
	for row in shown.size():
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size.y = ROW_H
		b.clip_contents = true
		var rt := RichTextLabel.new()
		rt.bbcode_enabled = true
		rt.scroll_active = false
		rt.autowrap_mode = TextServer.AUTOWRAP_OFF
		rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rt.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		rt.offset_left = 8
		rt.offset_top = 4
		b.add_child(rt)
		b.pressed.connect(activate.bind(row))
		b.mouse_entered.connect(select.bind(row))
		_list.add_child(b)
		rows.append(b)
		_update_row(row)


func _update_row(row: int) -> void:
	var it := item_at(row)
	var prefix := ""
	if filter_edit == null and row < 9:
		prefix = "%d  " % (row + 1)
	var suffix := ""
	if kind == "item_multi":
		var on := picks.has(it["id"])
		prefix += "[lb]x[rb] " if on else "[lb]  [rb] "
		if on:
			var n: int = picks[it["id"]]
			suffix = "   [color=#ffd060]%s[/color]" % ("all" if n == 0 else "x %d" % n)
	var rt := rows[row].get_child(0) as RichTextLabel
	rt.text = prefix + CddaText.to_bbcode((it["label"] as String).replace("\n", " ")) + suffix
	rows[row].modulate.a = 1.0 if it["enabled"] else 0.45
	mark(rows[row], row == selected)


func _show_desc() -> void:
	if _desc != null:
		var it := item_at(selected)
		_desc.text = CddaText.to_bbcode(it.get("description", ""))


func _sync_count() -> void:
	if count_spin == null:
		return
	var it := item_at(selected)
	count_spin.set_value_no_signal(picks.get(it.get("id"), 0) if not it.is_empty() else 0)


func _on_count_changed(v: float) -> void:
	var it := item_at(selected)
	if it.is_empty() or not it["enabled"]:
		return
	picks[it["id"]] = clampi(int(v), 0, MAX_COUNT)
	_update_row(selected)


func _ensure_visible(b: Button) -> void:
	if is_instance_valid(b) and b.is_inside_tree() and _scroll.is_inside_tree():
		_scroll.ensure_control_visible(b)
