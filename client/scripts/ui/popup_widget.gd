class_name PopupRequestWidget
extends RequestWidget
## `popup` requests (query_popup: query_yn, popup, ...): the text and one button per action. Left/Right/Tab
## choose, Enter or Space presses, Y/N answer YES/NO, 1-9 press a button, Esc cancels (or, when the popup
## can't be cancelled, answers QUIT, NO or CONFIRM if offered). Answer: `action`.
## Also shows a `key` request without actions (CDDA's "press any key" reads, context RAW_KEY): any key or the
## button answers " ". A request of a kind this client doesn't know shows its text with Cancel only.

const ESC_FALLBACK := ["QUIT", "NO", "CONFIRM"]

var actions := PackedStringArray()
var buttons: Array[Button] = []
var selected := 0
var any_key := false


func setup(req: Dictionary) -> void:
	super(req)
	var kind := str_of(req, "kind")
	add_header(req)
	any_key = kind == "key"
	if any_key:
		actions = PackedStringArray([" "])
	elif kind == "popup":
		actions = actions_of(req)
	else:
		add_rich("<color_light_red>This client can't answer a '%s' request yet.</color>" % kind.left(32))
	var bar := HFlowContainer.new()
	bar.alignment = FlowContainer.ALIGNMENT_CENTER
	add_child(bar)
	for i in actions.size():
		var label := "Continue" if any_key else action_label(actions[i])
		if actions.size() > 1 and i < 9:
			label = "%d  %s" % [i + 1, label]
		var b := add_button(label, press.bind(i), bar)
		b.custom_minimum_size.x = 90
		buttons.append(b)
	if allow_cancel and not any_key and not actions.has("QUIT"):
		add_button("Cancel (Esc)", cancel, bar)
	select(0)
	if any_key:
		add_hint("Any key continues")
	elif not actions.is_empty():
		add_hint("Left/Right choose  Enter press" + ("  Y/N" if actions.has("YES") else "") +
				("  Esc cancel" if allow_cancel else ""))


func select(i: int) -> void:
	if buttons.is_empty():
		return
	mark(buttons[selected], false)
	selected = wrapi(i, 0, buttons.size())
	mark(buttons[selected], true)


func press(i: int) -> void:
	if i >= 0 and i < actions.size():
		send({"action": actions[i]})


func handle_input(event: InputEvent) -> bool:
	if any_key:
		var ak := event as InputEventKey
		if ak != null and ak.pressed and not ak.echo:
			press(0)
			return true
		return false
	var key := key_of(event, true)
	if key == KEY_NONE:
		return false
	var k := event as InputEventKey
	match key:
		KEY_LEFT, KEY_UP:
			select(selected - 1)
		KEY_RIGHT, KEY_DOWN:
			select(selected + 1)
		KEY_TAB:
			select(selected + (-1 if k.shift_pressed else 1))
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if not k.echo:
				press(selected)
		KEY_ESCAPE:
			if not k.echo and not cancel():
				for a: String in ESC_FALLBACK:
					if actions.has(a):
						press(actions.find(a))
						break
		KEY_Y:
			if not k.echo and actions.has("YES"):
				press(actions.find("YES"))
		KEY_N:
			if not k.echo and actions.has("NO"):
				press(actions.find("NO"))
		_:
			if key >= KEY_1 and key <= KEY_9 and not k.echo:
				press(key - KEY_1)
				return true
			return false
	return true
