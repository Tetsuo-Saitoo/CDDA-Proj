class_name StringRequestWidget
extends RequestWidget
## `string` requests (string_input_popup): a text field holding CDDA's default text (`entries[0].label`).
## Enter sends, Esc cancels. The text goes out without control characters, within `max_len` characters and the
## bridge's 1024 bytes. Answer: `text`. An on-screen keyboard (TextKeys) under the field, for the laser, a mouse,
## a pad or the VR stick: shown from the start when `show_keys` (RequestUI.keyboard: on the VR panel), else behind
## the Keyboard button or a pad's Y. While it shows, the pad and the stick work its keys (its Enter sends).

var edit: LineEdit
var max_len := MAX_ANSWER_TEXT_BYTES
## Open with the on-screen keyboard showing (set before setup).
var show_keys := false
var keys: TextKeys
var keys_button: Button


func setup(req: Dictionary) -> void:
	super(req)
	add_header(req)
	var m := int_of(req, "max_len", 0, 0, 1 << 30)
	max_len = MAX_ANSWER_TEXT_BYTES if m <= 0 else mini(m, MAX_ANSWER_TEXT_BYTES)
	edit = LineEdit.new()
	edit.max_length = max_len
	var entries := entries_of(req)
	edit.text = clean(entries[0]["label"] if not entries.is_empty() else "", max_len)
	edit.select_all_on_focus = true
	edit.custom_minimum_size.x = 420
	edit.text_submitted.connect(func(_t: String) -> void: submit())
	add_child(edit)
	edit.set_meta(TextKeysDock.OWN_KEYS, true)   # the dock leaves this field to the keys below
	keys = TextKeys.new()
	keys.target = edit
	keys.enter.connect(submit)
	keys.visible = show_keys
	add_child(keys)
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_END
	add_child(bar)
	keys_button = add_button("Keyboard", toggle_keys, bar)
	add_button("OK (Enter)", submit, bar)
	if allow_cancel:
		add_button("Cancel (Esc)", cancel, bar)
	focus_later(edit)


## Shows or hides the on-screen keyboard.
func toggle_keys() -> void:
	keys.visible = not keys.visible
	mark(keys_button, keys.visible)


## The pad opens the keys with Y; while they show, the pad and the stick's ui_* actions work them (B / ui_cancel
## still cancels the prompt, through handle_input).
func handle_raw(event: InputEvent) -> bool:
	if done or event == null:
		return false
	if not keys.visible:
		var pad := event as InputEventJoypadButton
		if pad != null and pad.pressed and pad.button_index == JOY_BUTTON_Y:
			toggle_keys()
			return true
		return false
	return keys.handle_input(event)


func submit() -> void:
	send({"text": clean(edit.text, max_len)})


## `s` without control characters, at most `max_chars` characters and 1024 UTF-8 bytes.
static func clean(s: String, max_chars: int) -> String:
	var out := PackedStringArray()
	for i in mini(s.length(), max_chars * 4):
		var c := s.unicode_at(i)
		if c >= 32 and not (c >= 127 and c < 160):
			out.append(s[i])
	var t := "".join(out).left(max_chars)
	while t.to_utf8_buffer().size() > MAX_ANSWER_TEXT_BYTES:
		t = t.left(t.length() - 1)
	return t


func handle_input(event: InputEvent) -> bool:
	match key_of(event):
		KEY_ENTER, KEY_KP_ENTER:
			submit()
			return true
		KEY_ESCAPE:
			cancel()
			return true
	return false
