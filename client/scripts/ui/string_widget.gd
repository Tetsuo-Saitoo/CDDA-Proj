class_name StringRequestWidget
extends RequestWidget
## `string` requests (string_input_popup): a text field holding CDDA's default text (`entries[0].label`).
## Enter sends, Esc cancels. The text goes out without control characters, within `max_len` characters and the
## bridge's 1024 bytes. Answer: `text`.

var edit: LineEdit
var max_len := MAX_ANSWER_TEXT_BYTES


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
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_END
	add_child(bar)
	add_button("OK (Enter)", submit, bar)
	if allow_cancel:
		add_button("Cancel (Esc)", cancel, bar)
	focus_later(edit)


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
