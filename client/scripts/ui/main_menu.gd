class_name MainMenu
extends PanelContainer
## The live game's main menu (CDDA's own main menu, drawn by the client): New game (new or existing world,
## custom or random character), Load game (world, then character), Quit. It only picks; main.gd starts the
## game through LiveSession. World and save names come from CddaSim.list_worlds / list_saves (the folders
## under the user dir), so they are shown as plain text and a new world may not reuse an existing name (the
## bridge would replace that world). Plain Controls, so it can later sit on a world-space panel in VR.

signal new_game(world: String, fresh_world: bool, chargen: bool)
signal load_game(world: String, save: String)
signal quit_requested

const MAX_LISTED := 256
const WORLD_NAME_MAX := 32

var worlds := PackedStringArray()
## world -> PackedStringArray of saves; Callable(world) -> PackedStringArray.
var saves_of := Callable()
var page := ""
var message := ""
var _box: VBoxContainer
var _msg: Label
var _world_list: ItemList
var _save_list: ItemList
var _world_edit: LineEdit
var _use_existing: CheckBox
var _custom: CheckBox


func _init() -> void:
	name = "MainMenu"
	custom_minimum_size = Vector2(460, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.09, 0.95)
	style.border_color = Color(0.35, 0.35, 0.4)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(18)
	add_theme_stylebox_override("panel", style)
	_box = VBoxContainer.new()
	add_child(_box)


## Fills the menu: `world_names` from list_worlds, `saves` a Callable(world) -> PackedStringArray.
func setup(world_names: PackedStringArray, saves: Callable) -> void:
	worlds = PackedStringArray()
	for w in world_names:
		if worlds.size() < MAX_LISTED and world_name_ok(w):
			worlds.append(w)
	saves_of = saves
	show_page("main")


## A name the bridge accepts for a new world: 1-32 of A-Z a-z 0-9 _ -.
static func world_name_ok(n: String) -> bool:
	if n.is_empty() or n.length() > WORLD_NAME_MAX:
		return false
	for c in n:
		if not (c >= "a" and c <= "z" or c >= "A" and c <= "Z" or c >= "0" and c <= "9" or c == "_" or c == "-"):
			return false
	return true


## A fresh world name that isn't taken ("World", "World2", ...).
func suggested_world() -> String:
	var n := "World"
	var i := 1
	while worlds.has(n):
		i += 1
		n = "World%d" % i
	return n


func show_page(p: String) -> void:
	page = p
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	_world_list = null
	_save_list = null
	var title := Label.new()
	title.add_theme_font_size_override("font_size", 22)
	_box.add_child(title)
	match p:
		"main":
			title.text = "Cataclysm: Dark Days Ahead 3D"
			_button("New game", func() -> void: show_page("new"))
			var load := _button("Load game", func() -> void: show_page("load"))
			load.disabled = worlds.is_empty()
			_button("Quit", func() -> void: quit_requested.emit())
		"new":
			title.text = "New game"
			_use_existing = CheckBox.new()
			_use_existing.text = "Add a character to an existing world"
			_use_existing.disabled = worlds.is_empty()
			_box.add_child(_use_existing)
			_world_list = _list(worlds)
			_world_edit = LineEdit.new()
			_world_edit.placeholder_text = "new world name"
			_world_edit.text = suggested_world()
			_world_edit.max_length = WORLD_NAME_MAX
			_box.add_child(_world_edit)
			_use_existing.toggled.connect(func(on: bool) -> void:
				_world_list.visible = on
				_world_edit.visible = not on)
			_world_list.visible = false
			_custom = CheckBox.new()
			_custom.text = "Create the character (off: a random one)"
			_custom.button_pressed = true
			_box.add_child(_custom)
			_button("Start", start_new)
			_button("Back", func() -> void: show_page("main"))
		"load":
			title.text = "Load game"
			_world_list = _list(worlds)
			_save_list = _list(PackedStringArray())
			_world_list.item_selected.connect(func(_i: int) -> void: _fill_saves())
			if not worlds.is_empty():
				_world_list.select(0)
				_fill_saves()
			_button("Load", start_load)
			_button("Back", func() -> void: show_page("main"))
	_msg = Label.new()
	_msg.add_theme_color_override("font_color", Color(1.0, 0.5, 0.45))
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.text = message
	_box.add_child(_msg)


func set_message(m: String) -> void:
	message = m
	if _msg != null:
		_msg.text = m


## "New game" page: emits new_game if the choice is valid; true if it did.
func start_new() -> bool:
	var existing := _use_existing != null and _use_existing.button_pressed
	var world := ""
	if existing:
		world = _selected(_world_list, worlds)
		if world.is_empty():
			set_message("Pick a world.")
			return false
	else:
		world = _world_edit.text.strip_edges()
		if not world_name_ok(world):
			set_message("World names are 1-32 letters, digits, _ or -.")
			return false
		if worlds.has(world):
			set_message("A world named %s exists: pick another name or add the character to it." % world)
			return false
	set_message("")
	new_game.emit(world, not existing, _custom == null or _custom.button_pressed)
	return true


## "Load game" page: emits load_game for the selected save; true if it did.
func start_load() -> bool:
	var world := _selected(_world_list, worlds)
	var saves := _saves(world)
	var save := _selected(_save_list, saves)
	if world.is_empty() or save.is_empty():
		set_message("Pick a world and a character.")
		return false
	set_message("")
	load_game.emit(world, save)
	return true


func select_world(world: String) -> bool:
	var i := worlds.find(world)
	if _world_list == null or i < 0:
		return false
	_world_list.select(i)
	if _save_list != null:
		_fill_saves()
	return true


func _saves(world: String) -> PackedStringArray:
	if world.is_empty() or not saves_of.is_valid():
		return PackedStringArray()
	var v: Variant = saves_of.call(world)
	return (v as PackedStringArray).slice(0, MAX_LISTED) if v is PackedStringArray else PackedStringArray()


func _fill_saves() -> void:
	_save_list.clear()
	for s in _saves(_selected(_world_list, worlds)):
		_save_list.add_item(s)
	if _save_list.item_count > 0:
		_save_list.select(0)


func _selected(list: ItemList, names: PackedStringArray) -> String:
	if list == null:
		return ""
	var sel := list.get_selected_items()
	if sel.is_empty() or sel[0] >= names.size():
		return ""
	return names[sel[0]]


func _list(names: PackedStringArray) -> ItemList:
	var l := ItemList.new()
	l.custom_minimum_size.y = 140
	for n in names:
		l.add_item(n)
	_box.add_child(l)
	return l


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_press)
	_box.add_child(b)
	return b
