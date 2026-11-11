class_name PourHold
extends RefCounted
## Block E6: hold E to pour. While a hand holds a container with liquid in it (`held`), E waits for its release:
## a tap does what E always does (`tap`: take the item under the pointer, else use / examine what you face), and
## holding it HOLD_MS pours, once, through ItemActions (CDDA's liquid rules decide): into the container under the
## pointer when there is one, else onto the square you face. With nothing liquid in hand E isn't touched here.

const HOLD_MS := 450

var actions: ItemActions
## () -> ItemRef or null: the carried container with liquid in a hand (main hand first).
var held := Callable()
## () -> Dictionary: where a pour goes now: {container: ItemRef} or {square: Vector3i}; {} nowhere.
var target := Callable()
## () -> void: E's tap.
var tap := Callable()

var _down := -1             # msec E went down with a liquid in hand, -1 when not waiting
var _item: ItemRef


## E pressed or released (echoes too while waiting); true when it was used here.
func handle(event: InputEvent, now: int) -> bool:
	if _down >= 0:
		if event.is_action_released(&"use_held"):
			cancel()
			if tap.is_valid():
				tap.call()
			return true
		return event.is_action(&"use_held")   # key repeats while held
	if not InputActions.pressed(event, &"use_held"):
		return false
	var it: Variant = held.call() if held.is_valid() else null
	if not it is ItemRef:
		return false
	_down = now
	_item = it
	return true


## Per frame: once E has been held HOLD_MS, pours. Returns what was sent ("pour" onto a square, "pour_into" a
## container), "refused" when ItemActions sent nothing, "" while waiting or idle.
func update(now: int) -> String:
	if _down < 0 or now - _down < HOLD_MS:
		return ""
	var it := _item
	cancel()
	var t: Variant = target.call() if target.is_valid() else {}
	var where: Dictionary = t if t is Dictionary else {}
	if actions == null or it == null:
		return "refused"
	var c: Variant = where.get("container")
	if c is ItemRef:
		return "pour_into" if actions.pour_into(it, c, int(where.get("pocket", -1))) else "refused"
	var sq: Variant = where.get("square")
	if sq is Vector3i:
		return "pour" if actions.pour(it, sq) else "refused"
	return "refused"


## Waiting for E's release (a liquid in hand).
func waiting() -> bool:
	return _down >= 0


## Forgets a press (a menu opened over it): nothing is sent, no tap.
func cancel() -> void:
	_down = -1
	_item = null


## The HUD's line: "hold E: pour it out" / "hold E: pour into the jug"; "" with no liquid in hand.
func hint(tables: IdTables) -> String:
	var it: Variant = held.call() if held.is_valid() else null
	if not it is ItemRef:
		return ""
	var t: Variant = target.call() if target.is_valid() else {}
	var c: Variant = (t as Dictionary).get("container") if t is Dictionary else null
	var k := InputActions.key_of(&"use_held")
	if c is ItemRef:
		return "hold %s: pour into the %s" % [k, InventoryModel.clean((c as ItemRef).display_name(tables), 40)]
	return "hold %s: pour it out" % k
