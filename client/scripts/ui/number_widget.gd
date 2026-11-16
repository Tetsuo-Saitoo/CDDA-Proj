class_name NumberRequestWidget
extends StringRequestWidget
## `number` requests (CDDA's query_int, query_int64_t, edit(int)): a field holding the default, a whole number
## from `min` to `max`. Enter sends, Esc cancels; Up / Down and the -1 / +1 buttons (a pointer, the VR panel) step
## it within the range. A text that isn't a whole number in the range isn't sent: the line under the field says
## why. The bridge checks again and asks once more with `status` (shown in red). Answer: `number` (an int).
## The on-screen keyboard is the string widget's.

## The bridge never sends a range beyond this (JSON numbers are doubles).
const LIMIT := (1 << 53) - 1
const MAX_DIGITS := 16
const INT32_MIN := -2147483648
const INT32_MAX := 2147483647

var lo := -LIMIT
var hi := LIMIT
var problem: Label


func setup(req: Dictionary) -> void:
	super(req)
	lo = int_of(req, "min", -LIMIT, -LIMIT, LIMIT)
	hi = int_of(req, "max", LIMIT, -LIMIT, LIMIT)
	if lo > hi:   # a broken range: take it the right way round
		var t := lo
		lo = hi
		hi = t
	var start := clampi(int_of(req, "default", clampi(0, lo, hi), -LIMIT, LIMIT), lo, hi)
	edit.max_length = MAX_DIGITS + 1
	edit.text = str(start)
	edit.custom_minimum_size.x = 240
	var at := edit.get_index()
	var hint := Label.new()
	hint.text = range_text(lo, hi)
	hint.add_theme_color_override("font_color", HINT_COLOR)
	add_child(hint)
	move_child(hint, at)
	problem = Label.new()
	problem.name = "Problem"
	problem.add_theme_color_override("font_color", Color(1.0, 0.5, 0.45))
	problem.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	problem.text = Snapshot.plain_text(req.get("status"), MAX_LABEL)   # the bridge's reason for asking again
	problem.visible = not problem.text.is_empty()
	add_child(problem)
	move_child(problem, edit.get_index() + 1)
	var bar := keys_button.get_parent()
	var minus := add_button("-1", step.bind(-1), bar)
	var plus := add_button("+1", step.bind(1), bar)
	bar.move_child(minus, 0)
	bar.move_child(plus, 1)


## "A whole number from 1 to 20." ("A whole number." for the whole int range.)
static func range_text(from: int, to: int) -> String:
	if from <= INT32_MIN and to >= INT32_MAX:
		return "A whole number."
	if from <= INT32_MIN:
		return "A whole number up to %d." % to
	if to >= INT32_MAX:
		return "A whole number from %d up." % from
	return "A whole number from %d to %d." % [from, to]


## `s` as a whole number from `from` to `to`, or null: an optional sign, then 1..16 digits (spaces around it are
## fine, nothing else is).
static func parse(s: String, from: int, to: int) -> Variant:
	var t := s.strip_edges()
	var neg := t.begins_with("-")
	if neg or t.begins_with("+"):
		t = t.substr(1)
	if t.is_empty() or t.length() > MAX_DIGITS:
		return null
	for i in t.length():
		var c := t.unicode_at(i)
		if c < 48 or c > 57:
			return null
	var n := t.to_int()
	if neg:
		n = -n
	return n if n >= from and n <= to else null


## Adds `by` to the number in the field (the default when it isn't one), within the range.
func step(by: int) -> void:
	var v: Variant = parse(edit.text, -LIMIT, LIMIT)
	var n: int = v if v != null else clampi(0, lo, hi)
	edit.text = str(clampi(n + by, lo, hi))
	edit.caret_column = edit.text.length()
	problem.visible = false


func submit() -> void:
	var v: Variant = parse(edit.text, lo, hi)
	if v == null:
		problem.text = "Enter a whole number from %d to %d." % [lo, hi]
		problem.visible = true
		return
	send({"number": v})


func handle_input(event: InputEvent) -> bool:
	match key_of(event):
		KEY_UP:
			step(1)
			return true
		KEY_DOWN:
			step(-1)
			return true
	return super(event)
