class_name VrResults
extends RefCounted
## Block L9, VR: the bridge's answers to VR's own item ops (VrCook's cook, VrFire's light and extinguish). Each op
## goes out with a tag from `open` (TAG_BASE..TAG_END: under ItemActions' tags, far over what ItemPlacer counts up
## to from 1), and the `item_result` event carrying it (contracts/events.md) says done or refused, with the
## refusal's text. CDDA often says why in a message instead and leaves that text empty: messages that arrive while
## an op waits are kept as its reason (the last one; NOT_DONE when there is none, as when the player said no to
## CDDA's question). VrRig shows the answers.
## Events are hostile: anything but a tag in flight, a whole number in range, is skipped; texts are cleaned (one
## line, no control characters, TEXT_MAX). At most MAX_OPS wait (a new one pushes out the oldest); one unanswered
## for FORGET_S is dropped without a word (CDDA runs item ops only while its clock runs).

const TAG_BASE := 1 << 29
const TAG_END := (1 << 30) - 1   # ItemActions.TAG_BASE - 1
const MAX_OPS := 16
const MAX_EVENTS := 4096          # the bridge's event queue
const MAX_MESSAGES := 4           # messages kept per op
const TEXT_MAX := 120
const FORGET_S := 120.0
const NOT_DONE := "Not done."

var _ops := {}     # tag -> {info, messages: Array[String], at}, oldest first
var _tag := 0      # the last tag given, TAG_BASE..TAG_END (0: none yet)
var _clock := 0.0


## A tag for an op about to go out, kept with `info` (handed back with its answer). `close` it when the op wasn't
## sent after all.
func open(info: Dictionary) -> int:
	_tag = TAG_BASE if _tag < TAG_BASE or _tag >= TAG_END else _tag + 1
	_ops.erase(_tag)
	while _ops.size() >= MAX_OPS:
		_ops.erase(_ops.keys()[0])
	var kept: Array[String] = []
	_ops[_tag] = {"info": info, "messages": kept, "at": _clock}
	return _tag


func close(tag: int) -> void:
	_ops.erase(tag)


## Ops waiting for their answer.
func waiting() -> int:
	return _ops.size()


## Every frame: drops ops unanswered for FORGET_S.
func tick(delta: float) -> void:
	_clock += clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	for tag: int in _ops.keys():
		if _clock - float(_ops[tag]["at"]) > FORGET_S:
			_ops.erase(tag)


## The bridge's events (LiveSession.events_arrived): the answers among them, in order, each {info (as given to
## open), done, why (the reason when refused, else ""), said (the last message since the op went out, "" none)}.
func on_events(events: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _ops.is_empty() or not events is Array:
		return out
	var evs: Array = events
	for k in mini(evs.size(), MAX_EVENTS):
		if not evs[k] is Dictionary:
			continue
		var ev: Dictionary = evs[k]
		var kind: Variant = ev.get("kind")
		if kind is String and kind == "message":
			var text := clean(ev.get("text"))
			if text.is_empty():
				continue
			for tag: int in _ops:
				var kept: Array[String] = _ops[tag]["messages"]
				kept.append(text)
				if kept.size() > MAX_MESSAGES:
					kept.pop_front()
		elif kind is String and kind == "item_result":
			var tag := whole(ev.get("detail"))
			if tag < TAG_BASE or tag > TAG_END or not _ops.has(tag):
				continue
			var op: Dictionary = _ops[tag]
			_ops.erase(tag)
			var kept: Array[String] = op["messages"]
			var said: String = kept.back() if not kept.is_empty() else ""
			var done := whole(ev.get("amount")) == 1
			var why := ""
			if not done:
				why = clean(ev.get("text"))
				if why.is_empty():
					why = said if not said.is_empty() else NOT_DONE
			out.append({"info": op["info"], "done": done, "why": why, "said": said})
	return out


## `v` as a whole number (an int, or a whole finite float as raw JSON gives) in 0..2^31-1; -1 anything else.
static func whole(v: Variant) -> int:
	if v is int:
		return v if v >= 0 and v <= 2147483647 else -1
	if v is float and is_finite(v) and v >= 0.0 and v <= 2147483647.0 and v == floorf(v):
		return int(v)
	return -1


## A text from the sim as one line: control characters become spaces, at most TEXT_MAX characters; "" for anything
## not a String.
static func clean(v: Variant) -> String:
	if not v is String:
		return ""
	var out := ""
	for c in (v as String).left(TEXT_MAX):
		out += " " if c.unicode_at(0) < 32 or c.unicode_at(0) == 127 else c
	return out.strip_edges()
