class_name LeanPeek
extends RefCounted
## Leaning to peek (eye tracking idea 9; needs no eye tracker): the flat lean keys and VR's physical lean (lead-vr,
## through main's lean / unlean). A lean held HOLD_MS queues CDDA's `peek` toward the neighbouring square
## (LiveSession.queue_action_at, no prompt). Its target request (mode peek) is held without a UI while the lean
## lasts (the game stands still; the snapshot shows the view from the peeked square), then answered with cancel.
## One try per lean: a refused peek (the main loop asks again with no peek request in between) isn't sent again
## until the next lean. Only squares go to the bridge.

const HOLD_MS := 250
const WAYS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0),
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]   # main.gd's OCT_ACTIONS order (x east, y south)

var dir := Vector2i.ZERO   # the way leaned, ZERO none
var _since_ms := 0
var _tried := false        # this lean's peek was queued (or the bridge refused to queue it)
var _pending := false      # queued, its request not seen yet
var _req_id := -1          # the peek request held open for this lean, -1 none


func leaning() -> bool:
	return dir != Vector2i.ZERO


## True while CDDA's peek is open (its request held).
func peeking() -> bool:
	return _req_id >= 0


## Starts a lean toward the neighbouring square `d` (one of the 8 ways); false for anything else. Leaning another
## way starts over.
func lean(d: Vector2i, now_ms: int) -> bool:
	if not d in WAYS:
		return false
	if d != dir:
		dir = d
		_since_ms = now_ms
		_tried = false
	return true


## Ends the lean: the answer that ends an open peek ({id, cancel}), else {}.
func unlean() -> Dictionary:
	dir = Vector2i.ZERO
	_tried = false
	if _req_id < 0:
		return {}
	var a := {"id": _req_id, "cancel": true}
	_req_id = -1
	return a


## The square to peek toward now (player + dir), once per lean, HOLD_MS after it started and only in the main loop
## (`ready`); null otherwise. Call sent() with whether the bridge took it.
func peek_square(now_ms: int, ready: bool, player: Vector3i) -> Variant:
	if not leaning() or _tried or _pending or not ready or now_ms - _since_ms < HOLD_MS:
		return null
	_tried = true
	return player + Vector3i(dir.x, dir.y, 0)


func sent(ok: bool) -> void:
	_pending = ok


## A request from the game. null: not this lean's peek (show it as usual). {}: it is, held with no UI. {id, cancel}:
## it is, but the lean is over: send that.
func on_request(req: Dictionary) -> Variant:
	if not _pending or req.is_empty():   # no request for a moment: the bridge between the step and the peek's request
		return null
	if req.get("timed", false):
		_pending = false   # refused: the main loop asks again
		return null
	var id: Variant = RequestWidget.id_value(req.get("id"))
	if str(req.get("kind", "")) != "target" or str(req.get("mode", "")) != "peek" or id == null or id <= 0:
		return null
	_pending = false
	if leaning():
		_req_id = id
		return {}
	return {"id": id, "cancel": true}


## Every request change: another request (not a moment with none) means the game moved on by itself, so nothing is
## held.
func request_seen(req: Dictionary) -> void:
	if _req_id >= 0 and not req.is_empty() and RequestWidget.id_value(req.get("id")) != _req_id:
		_req_id = -1
