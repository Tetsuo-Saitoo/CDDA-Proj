class_name Hotbar
extends HBoxContainer
## G2 hotbar (flat screen): SLOTS item types that the number keys 3..9 and 0 (hotbar_1..hotbar_8, rebindable; 1 and
## 2 are the hand strikes) put into the main hand. The key takes the first carried item of the slot's type that is
## neither worn nor already in the main hand (ItemActions.hold, CDDA's wield). In the Tab view the key, with one item
## selected, puts that item's type in the slot (the same type again empties it; a type sits in one slot only).
## Slots hold CDDA item type ids, saved in user://hotbar.cfg; the file is treated as hostile (size cap, no
## Object(...), each id checked). The bar sits at the bottom centre while a slot is set or the Tab view is open:
## each slot's key and short name, dim when none is carried, bright when one is in the main hand.

const SLOTS := 8
const FILE := "user://hotbar.cfg"
const MAX_FILE_BYTES := 8 << 10
const MAX_ID := 64
const SHORT := 14   # characters of a name on the bar
const DIM := Color(1, 1, 1, 0.45)
const LIT := Color(1.0, 0.85, 0.4)

var slots := PackedStringArray()   # a CDDA item type id per slot, "" = empty
var path := FILE
var actions: ItemActions
var world: WorldView          # its snapshot and id tables
var show_empty := false:      # main: while the Tab view is open, the bar shows even with no slot set
	set(on):
		show_empty = on
		refresh()
var _labels: Array[Label] = []


func _init() -> void:
	name = "Hotbar"
	slots.resize(SLOTS)
	set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_bottom = -8
	add_theme_constant_override("separation", 6)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in SLOTS:
		var l := Label.new()
		l.custom_minimum_size = Vector2(96, 0)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 4)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(l)
		_labels.append(l)
	visible = false


## The input action of slot `i` (0-based).
static func action(i: int) -> StringName:
	return StringName("hotbar_%d" % (i + 1))


## A CDDA item type id as kept here: 1..MAX_ID of A-Z a-z 0-9 _ - (anything else isn't one).
static func id_ok(v: Variant) -> bool:
	if not v is String:
		return false
	var s: String = v
	if s.is_empty() or s.length() > MAX_ID:
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c == 45):
			return false
	return true


## Reads the file; returns "" or why it was ignored (missing is not an error). Bad ids leave their slot empty.
func load_file() -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "cannot open %s" % path
	if f.get_length() > MAX_FILE_BYTES:
		return "%s is over %d bytes" % [path, MAX_FILE_BYTES]
	var text := f.get_as_text()
	for bad: String in ["Object(", "Resource(", "ExtResource(", "SubResource("]:
		if bad in text:
			return "%s has %s, ignored" % [path, bad]
	var cfg := ConfigFile.new()
	if cfg.parse(text) != OK:
		return "%s doesn't parse" % path
	var v: Variant = cfg.get_value("hotbar", "slots", [])
	slots = PackedStringArray()
	slots.resize(SLOTS)
	if not (v is Array or v is PackedStringArray):
		return "%s: slots is not a list" % path
	var given: Array = Array(v).slice(0, SLOTS)
	for i in given.size():
		if id_ok(given[i]) and not slots.has(given[i]):
			slots[i] = given[i]
	refresh()
	return ""


func save_file() -> Error:
	var cfg := ConfigFile.new()
	var out: Array[String] = []
	for s in slots:
		out.append(s if id_ok(s) else "")
	cfg.set_value("hotbar", "slots", out)
	return cfg.save(path)


## Puts type `type_id` in slot `i` (taking it out of any other slot); the same type again empties the slot. Saved.
## Returns the line to show.
func assign(i: int, type_id: String) -> String:
	if i < 0 or i >= SLOTS or not id_ok(type_id):
		return "That item can't go on the hotbar."
	var key := key_name(i)
	if slots[i] == type_id:
		slots[i] = ""
		_save_and_show()
		return "Hotbar %s emptied." % key
	for j in SLOTS:
		if slots[j] == type_id:
			slots[j] = ""
	slots[i] = type_id
	_save_and_show()
	return "Hotbar %s: %s." % [key, _name_of(type_id, 64)]


## The first carried item of type `type_id` in `snap` that is neither worn nor in the main hand; null when none.
static func find(snap: Snapshot, tables: IdTables, type_id: String) -> ItemRef:
	if snap == null or tables == null or not id_ok(type_id):
		return null
	var t := tables.index_of("itype", type_id)
	if t <= 0:
		return null
	var c := snap.carried
	var n := Snapshot.CARRIED_STRIDE
	for i in range(0, c.size() - n + 1, n):
		if c[i + 1] != t or c[i + 4] & (Snapshot.CARRIED_WORN | Snapshot.CARRIED_WIELDED):
			continue
		return ItemRef.on_player(c[i], t, c[i + 2], c[i + 3], c[i + 4], snap.player_pos)
	return null


## Slot `type_id`'s state in `snap`: "in_hand" (the main hand holds one), "carried", "none" or "empty".
static func state(snap: Snapshot, tables: IdTables, type_id: String) -> String:
	if not id_ok(type_id):
		return "empty"
	if snap == null or tables == null:
		return "none"
	var t := tables.index_of("itype", type_id)
	var c := snap.carried
	var n := Snapshot.CARRIED_STRIDE
	var have := false
	for i in range(0, c.size() - n + 1, n):
		if t > 0 and c[i + 1] == t:
			if c[i + 4] & Snapshot.CARRIED_WIELDED:
				return "in_hand"
			have = have or not (c[i + 4] & Snapshot.CARRIED_WORN)
	return "carried" if have else "none"


## Slot `i`'s key as short text: the first key bound to its action ("-" when none).
static func key_name(i: int) -> String:
	return InputActions.key_of(action(i)) if InputMap.has_action(action(i)) else "-"


## The key of slot `i` pressed in the game: its item into the main hand. Returns the line to show ("" when sent).
func use(i: int) -> String:
	if i < 0 or i >= SLOTS:
		return ""
	var key := key_name(i)
	if slots[i] == "":
		return "Hotbar %s is empty: in the Tab view, pick an item and press %s." % [key, key]
	var snap := world.snapshot if world != null else null
	var tables := world.tables if world != null else null
	var nm := _name_of(slots[i], 64)
	if state(snap, tables, slots[i]) == "in_hand":
		return "The %s is already in your hand." % nm
	var it := find(snap, tables, slots[i])
	if it == null:
		return "You aren't carrying a %s." % nm
	if actions == null or not actions.hold(it, "main"):
		return "Can't take the %s out now." % nm
	return ""


## Redraws the slots from the newest snapshot (main calls it on each one).
func refresh() -> void:
	var snap := world.snapshot if world != null else null
	var tables := world.tables if world != null else null
	var any := false
	for i in SLOTS:
		var l := _labels[i]
		var id := slots[i] if i < slots.size() else ""
		any = any or id != ""
		var st := state(snap, tables, id)
		l.text = "%s %s" % [key_name(i), _name_of(id, SHORT) if id != "" else "-"]
		l.modulate = LIT if st == "in_hand" else (Color.WHITE if st == "carried" else DIM)
		l.tooltip_text = _name_of(id, 64) if id != "" else ""
	visible = any or show_empty


func _save_and_show() -> void:
	var err := save_file()
	if err != OK:
		push_warning("hotbar not saved: %s" % error_string(err))
	refresh()


## The item type's name from the id tables (its id when the tables don't have it), cleaned and cut to `cap`.
func _name_of(type_id: String, cap: int) -> String:
	var tables := world.tables if world != null else null
	var d := tables.def_named("itype", type_id) if tables != null else null
	var nm := d.name if d != null and d.name != "" else type_id
	return InventoryModel.clean(nm, cap)
