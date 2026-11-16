class_name RequestWidget
extends VBoxContainer
## Base of the request widgets; RequestUI makes one per request kind. A widget reads a request Dictionary
## (fields in contracts/bridge_api.md) and emits `answered` once with a well-formed answer Dictionary for
## LiveSession.answer(). Requests come from the sim, so every field is read defensively and lists are capped.

signal answered(answer: Dictionary)

const MAX_ENTRIES := 4096
const MAX_ACTIONS := 256
const MAX_LABEL := 400
const MAX_TEXT := 8000
const MAX_ACTION_BYTES := 64        # the bridge refuses longer actions
const MAX_ANSWER_TEXT_BYTES := 1024
const MAX_PICKS := 4096
const LONG_TEXT_CHARS := 700
const LONG_TEXT_LINES := 12
const HINT_COLOR := Color(0.7, 0.7, 0.7)
## Readable names for CDDA's common action ids; others are shown as "Some action".
const ACTION_NAMES := {
	"CONFIRM": "OK", "YES": "Yes", "NO": "No", "QUIT": "Cancel", "ANY_INPUT": "Continue",
	"HELP_KEYBINDINGS": "Keybindings",
}
## Key -> (right, forward) on screen, the same in every widget that moves something.
const MOVE_KEYS := {
	KEY_UP: Vector2(0, 1), KEY_DOWN: Vector2(0, -1), KEY_LEFT: Vector2(-1, 0), KEY_RIGHT: Vector2(1, 0),
	KEY_KP_8: Vector2(0, 1), KEY_KP_2: Vector2(0, -1), KEY_KP_4: Vector2(-1, 0), KEY_KP_6: Vector2(1, 0),
	KEY_KP_7: Vector2(-1, 1), KEY_KP_9: Vector2(1, 1), KEY_KP_1: Vector2(-1, -1), KEY_KP_3: Vector2(1, -1),
}

var request_id := 0
var allow_cancel := true
var done := false
## (right, forward) on screen -> CDDA step (x east, y south), each axis -1..1. Set by RequestUI.
var direction_mapper := Callable()


## Builds the widget for `req`. RequestUI has checked `id` and `kind`.
func setup(req: Dictionary) -> void:
	request_id = int(req["id"])
	allow_cancel = bool_of(req, "allow_cancel", true)


## A key or mouse event while the widget shows; true if used.
func handle_input(_event: InputEvent) -> bool:
	return false


## The same event as it came, before RequestUI turns pad buttons and ui_* actions into keys: for a widget that
## reads the pad itself (the on-screen keyboard). True if used; handle_input then doesn't get it.
func handle_raw(_event: InputEvent) -> bool:
	return false


## Sends cancel if the request allows it; true if it did.
func cancel() -> bool:
	if not allow_cancel:
		return false
	send({"cancel": true})
	return true


## Emits the answer (once): `fields` plus the request id.
func send(fields: Dictionary) -> void:
	if done:
		return
	done = true
	var a := {"id": request_id}
	a.merge(fields)
	answered.emit(a)


# --- Reading requests --------------------------------------------------------------------------------

static func str_of(req: Dictionary, key: String, max_chars := MAX_TEXT) -> String:
	var v: Variant = req.get(key)
	return (v as String).left(max_chars) if v is String else ""


static func bool_of(req: Dictionary, key: String, default: bool) -> bool:
	var v: Variant = req.get(key)
	return v if v is bool else default


static func int_of(req: Dictionary, key: String, default: int, lo: int, hi: int) -> int:
	var v: Variant = req.get(key)
	if v is int or (v is float and is_finite(v) and v == floorf(v)):
		return clampi(int(v), lo, hi)
	return default


static func vec_of(req: Dictionary, key: String) -> Vector3i:
	var v: Variant = req.get(key)
	return v if v is Vector3i else Vector3i.ZERO


## Integer value of an id field, or null.
static func id_value(v: Variant) -> Variant:
	if v is int:
		return v
	if v is float and is_finite(v) and v == floorf(v) and absf(v) < 2147483648.0:
		return int(v)
	return null


## The request's entries as [{id, label, enabled, description}], bad ones skipped, capped.
static func entries_of(req: Dictionary) -> Array:
	var out := []
	var list: Variant = req.get("entries")
	if not list is Array:
		return out
	for e: Variant in list:
		if out.size() >= MAX_ENTRIES:
			break
		if not e is Dictionary:
			continue
		var id: Variant = id_value((e as Dictionary).get("id"))
		if id == null or id < -2147483648 or id > 2147483647:
			continue
		out.append({"id": id, "label": str_of(e, "label", MAX_LABEL), "enabled": bool_of(e, "enabled", true),
				"description": str_of(e, "description", MAX_TEXT)})
	return out


## The request's actions, empty or over-long ones skipped, capped.
static func actions_of(req: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var list: Variant = req.get("actions")
	if not (list is PackedStringArray or list is Array):
		return out
	for a: Variant in list:
		if out.size() >= MAX_ACTIONS:
			break
		if a is String and not (a as String).is_empty() and (a as String).to_utf8_buffer().size() <= MAX_ACTION_BYTES:
			out.append(a)
	return out


static func action_label(action: String) -> String:
	if ACTION_NAMES.has(action):
		return ACTION_NAMES[action]
	return action.replace("_", " ").to_lower().capitalize() if action.strip_edges() != "" else "(space)"


# --- Building and input helpers ----------------------------------------------------------------------

## A RichTextLabel for CDDA text (converted to BBCode here).
func add_rich(cdda_text: String, parent: Control = self) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.text = CddaText.to_bbcode(cdda_text)
	parent.add_child(r)
	return r


## Title and text of the request, if any.
func add_header(req: Dictionary) -> void:
	var title := str_of(req, "title", MAX_LABEL)
	if not CddaText.plain(title).strip_edges().is_empty():
		var t := add_rich("<color_white>" + title + "</color>")
		t.add_theme_font_size_override("normal_font_size", 18)
	var text := str_of(req, "text")
	if not CddaText.plain(text).strip_edges().is_empty():
		var r := add_rich(text)
		if text.length() > LONG_TEXT_CHARS or text.count("\n") > LONG_TEXT_LINES:
			# Long texts (item info, help) scroll in a box of fixed height.
			r.fit_content = false
			r.scroll_active = true
			r.mouse_filter = Control.MOUSE_FILTER_STOP
			r.custom_minimum_size.y = 280


func add_button(label: String, on_press: Callable, parent: Control) -> Button:
	var b := Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_NONE   # widgets handle keys themselves (RequestUI._input)
	b.pressed.connect(on_press)
	parent.add_child(b)
	return b


func add_hint(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", HINT_COLOR)
	l.add_theme_font_size_override("font_size", 12)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(l)


## Shows `b` as the keyboard's current choice.
static func mark(b: Button, on: bool) -> void:
	if on:
		b.add_theme_stylebox_override("normal", b.get_theme_stylebox("hover"))
	else:
		b.remove_theme_stylebox_override("normal")


## The pressed key of `event` (layout-aware), or KEY_NONE. Repeats only when `allow_echo`.
static func key_of(event: InputEvent, allow_echo := false) -> Key:
	var k := event as InputEventKey
	if k == null or not k.pressed or (k.echo and not allow_echo):
		return KEY_NONE
	return k.keycode if k.keycode != KEY_NONE else k.physical_keycode


static func char_of(event: InputEvent) -> String:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo or k.unicode < 32:
		return ""
	return String.chr(k.unicode)


## Gives `c` the keyboard once the widget is laid out (if it is still showing then).
func focus_later(c: Control) -> void:
	_focus_now.call_deferred(c)


func _focus_now(c: Control) -> void:
	if not done and is_instance_valid(c) and c.is_visible_in_tree():
		c.grab_focus()


## Screen (right, forward) -> CDDA step, through `direction_mapper` (default: forward = north).
func map_step(v: Vector2) -> Vector2i:
	if direction_mapper.is_valid():
		var r: Variant = direction_mapper.call(v)
		if r is Vector2i and absi(r.x) <= 1 and absi(r.y) <= 1:
			return r
	return Vector2i(signi(roundi(v.x)), -signi(roundi(v.y)))
