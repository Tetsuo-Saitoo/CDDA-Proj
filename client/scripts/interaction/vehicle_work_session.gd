class_name VehicleWorkSession
extends RefCounted
## C6 vehicle work (lead-ui, 2026-11-23): the flow behind the flat-screen work view (VehicleWorkView) and VR's work
## panel (lead-vr): which vehicle, what to read (a part, or a square and a type to install), the reads, and the
## vehicle_work actions one at a time, held while the rows on screen may name other parts (VehicleWorkData.Gate).
## CDDA's rules decide; this only asks and sends. main makes one (main.work) and feeds it the reads, events and
## snapshots. One presenter at a time drives it: it keeps its own list and selection, tells the session what it shows
## (select, show_install, end_install), sends what the read allows (send, install) and listens to the signals.

## A read for this vehicle (VehicleWorkData.clean's Dictionary, ok or an error to show).
signal result(r: Dictionary)
## A sentence for the presenter (an action's outcome, CDDA's reason, why nothing was sent).
signal said(text: String)
## The session closed on `vehicle`: `why` is "" when a presenter closed it, else what to tell the player (gone, out of
## reach, an appliance). Opening it on another vehicle closes it on the first one ("").
signal closed(vehicle: int, why: String)
## CDDA's activity for `cmd` started: after "i" the presenter goes back to its parts list, after "o" its rows moved.
signal started(cmd: String)
## The action's part wasn't there any more: the presenter drops its selection (a new read comes).
signal moved
## The presenter shows part `row` (-1 none) / install square `at`: highlight it, point the work camera at it.
signal part_focused(row: int)
signal square_focused(at: Vector2i)
## A camera view was chosen ("around", "hood", "under"): main opens the hood and moves the work camera.
signal view_chosen(which: String)

## main's: what installing says when the game's install read isn't there.
const NO_INSTALL := "Installing isn't connected to the game yet."
const GONE := {"no such vehicle": "The vehicle is gone.", "too far": "The vehicle is out of reach.",
	"an appliance": "That's an appliance: examine it instead."}

var live: LiveSession   # null (or a bridge without the read): the snapshot's stand-in read, no actions
var world: Object       # its `snapshot` (Snapshot) and `tables` (IdTables): main's WorldView

var uid := 0             # the vehicle (0: closed)
var selected := -1       # the part the presenter shows (-1 none)
var installing := false  # install mode: the read is for install_at and install_pick
var install_at := Vector2i.ZERO
var install_pick := 0
var last := {}           # the last ok read (a part's vpart and mount for the action come from it)
var note := ""           # the last sentence said, or why open refused

var _parts := PackedInt32Array()    # the vehicle's parts and what the player carried when last asked
var _carried := PackedInt64Array()
var _again := false                 # a read was refused while one was out: ask again when it comes
var _tag := 0                       # the action waiting for its work_result (0 none)
var _sent := 0                      # ... sent at (msec)
var _cmd := ""                      # ... its command
var _for := 0                       # ... the vehicle it was sent for
var _starting := false              # work started since the last snapshot: the player counts as busy
var _gate := VehicleWorkData.Gate.new()


## Opens on vehicle `vehicle_uid` and asks for its read; false when it isn't in the snapshot or in reach (`note` says
## why, nothing else changes). A session open on another vehicle is closed first. Connect to the signals before.
func open(vehicle_uid: int) -> bool:
	var snap := snapshot()
	var veh := _vehicle(snap, vehicle_uid)
	if veh == null or not VehicleWorkData.in_reach(snap, veh):
		note = GONE["too far"] if veh != null else GONE["no such vehicle"]
		return false
	note = ""
	if uid != vehicle_uid:
		close()
	uid = vehicle_uid
	selected = -1
	installing = false
	install_pick = 0
	last = {}
	_parts = veh.parts
	_carried = snap.carried
	_again = false
	_gate = VehicleWorkData.Gate.new()
	if busy():
		_gate.changed()   # work runs: the list read now may be old when it ends
	ask()
	return true


func close() -> void:
	_end("")


## The presenter shows part `row` (-1 none): highlighted, and its read asked for.
func select(row: int) -> void:
	if uid == 0:
		return
	selected = row
	installing = false
	install_pick = 0
	part_focused.emit(row)
	ask()


## The presenter shows install mode on square `at` with type `vpart` picked (0 none yet): the read for them asked
## for. False when the game's install read isn't there (the presenter goes back to its parts list, NO_INSTALL).
func show_install(at: Vector2i, vpart := 0) -> bool:
	if uid == 0 or live == null or not live.has_vehicle_work() or not live.can_vehicle_work():
		return false
	installing = true
	install_at = at
	install_pick = vpart
	if vpart == 0:   # a new square (the parts list's highlight comes back with its row)
		square_focused.emit(at)
	ask()
	return true


## The presenter is back on its parts list (it selects a part next, which asks).
func end_install() -> void:
	installing = false
	install_pick = 0


func view(name: String) -> void:
	if uid != 0:
		view_chosen.emit(name)


## Says `text` to the presenter (main's camera views: no engine bay).
func say(text: String) -> void:
	_tell(text)


func _tell(text: String) -> void:
	note = text
	said.emit(text)


## Command `cmd` (r, o, m, f) on part `row` of the last read, which the presenter found allowed: sent as the
## vehicle_work action (the sim checks it all again; CDDA's own questions come as prompts). False, and said tells why,
## when nothing went out.
func send(cmd: String, row: int) -> bool:
	if not _can_send(cmd):
		return false
	var p := VehicleWorkData.part_of(last, row)
	if p.is_empty():
		_tell("Checking the parts again...")
		ask()
		return false
	_send(row, p["vpart"], p["mount"], cmd)
	return true


## Installs type `vpart` on square `at`, which the read allowed there: the action "i" (CDDA's questions come as
## prompts, a light's facing when the work finishes).
func install(vpart: int, at: Vector2i) -> bool:
	if not _can_send("i"):
		return false
	_send(-1, vpart, at, "i")
	return true


## The read for what the presenter shows: from the game (CDDA's checks) when its bridge answers it, else the
## snapshot's stand-in.
func ask() -> void:
	if uid == 0:
		return
	if live != null and live.has_vehicle_work():
		# refused (one still out, or the bridge busy): asked again when that one comes, else at the next snapshot
		var id := live.query_vehicle_work(uid, -1, install_at, install_pick) if installing \
				else live.query_vehicle_work(uid, selected)
		_again = id == 0
		if id > 0:
			_gate.asked(busy())
		return
	_gate.asked(busy())
	_gate.answered(true)   # the stand-in is read from this snapshot
	_show(VehicleWorkData.stand_in(snapshot(), world.get("tables") as IdTables if world != null else null, uid,
			selected))


## LiveSession.vehicle_work: a read came.
func on_read(r: Dictionary) -> void:
	if uid == 0 or r.get("vehicle") != uid:
		return
	_gate.answered(r.get("ok") == true)
	_show(r)
	if _again and uid != 0:
		_again = false
		ask()


## A new snapshot (main's _shown, every one): closed when the vehicle went or is out of reach, asked again when its
## parts or what the player carries changed (CDDA's checks depend on both).
func follow(snap: Snapshot) -> void:
	_starting = false   # this snapshot shows the started work's activity while it runs
	if uid == 0:
		return
	var veh := _vehicle(snap, uid)
	if veh == null or not VehicleWorkData.in_reach(snap, veh):
		_end(GONE["too far"] if veh != null else GONE["no such vehicle"])
		return
	var parts_moved := veh.parts != _parts
	if parts_moved:
		_gate.changed()   # the rows may have moved: actions wait for a read after this
	if parts_moved or snap.carried != _carried or (live != null and not live.vehicle_work_pending()
			and (_again or _gate.wants_read(busy()))):
		_parts = veh.parts
		_carried = snap.carried
		ask()


## LiveSession.events_arrived: the work_result for the action in flight: started (CDDA's activity runs; the next
## snapshot and read show what it did) or refused with CDDA's reason ("" when the player said no to its question).
func on_events(events: Array) -> void:
	if _tag < 1:
		return
	for i in mini(events.size(), 4096):
		var r := VehicleWorkData.work_result(events[i], _tag)
		if r.is_empty():
			continue
		_tag = 0
		if r["started"]:
			_starting = true   # the snapshot on screen is older than its activity
		if uid == 0 or _for != uid:
			return   # closed, or open on another vehicle: what it did shows in the next snapshot and read
		var gone: bool = not r["started"] and r["text"] == VehicleWorkData.MOVED
		if r["started"] or gone:
			_gate.changed()   # its activity changes the parts; or they changed under the list on screen
		if r["started"]:
			if _cmd == "i":
				end_install()   # the new part is the vehicle's last row once the work is done
			if _cmd == "o":
				selected = -1   # the rows after a removed part move up
			started.emit(_cmd)
			_tell("%s started." % VehicleWorkData.COMMAND_NAMES.get(_cmd, "Work"))
		else:
			_tell(r["text"] if not (r["text"] as String).is_empty() else "Not started.")
			if gone:
				selected = -1
				moved.emit()
				ask()   # read again
		return


## Whether the player's CDDA activity (a repair, a removal, a long wait) still runs.
func busy() -> bool:
	var snap := snapshot()
	return _starting or (snap != null and not (snap.activity_id.is_empty() and snap.activity_verb.is_empty()))


func snapshot() -> Snapshot:
	return world.get("snapshot") as Snapshot if world != null else null


## Whether an action may go out now; else said tells why (not connected, the player busy or the list old, the last
## one still starting).
func _can_send(cmd: String) -> bool:
	if uid == 0:
		return false
	if live == null or not live.can_vehicle_work() or not cmd in VehicleWorkData.ACTION_CMDS:
		_tell("%s isn't connected to the game yet." % VehicleWorkData.COMMAND_NAMES.get(cmd, "That"))
		return false
	var snap := snapshot()
	var why := _gate.held(busy(), snap.activity_verb if snap != null else "")
	if not why.is_empty():
		_tell(why)   # the action names its part by row: not while the rows may be old
		if _gate.wants_read(busy()) and not live.vehicle_work_pending():
			ask()   # no snapshot may come while the presenter waits: ask now
		return false
	if _tag > 0 and Time.get_ticks_msec() - _sent < LiveSession.QUERY_TIMEOUT_MS:
		_tell("Still starting the last one.")
		return false
	return true


func _send(row: int, vpart: int, mount: Vector2i, cmd: String) -> void:
	_tag = live.queue_vehicle_work(uid, row, vpart, mount, cmd)
	_sent = Time.get_ticks_msec()
	_for = uid
	_cmd = cmd
	_tell("Starting..." if _tag > 0 else "The game didn't take that now.")


## A read handed on; one saying the vehicle went, is out of reach or is an appliance closes the session instead.
func _show(r: Dictionary) -> void:
	if r.get("ok") != true and GONE.has(r.get("error")):
		_end(GONE[r["error"]])
		return
	if r.get("ok") == true:
		last = r
	result.emit(r)


func _end(why: String) -> void:
	if uid == 0:
		return
	var was := uid
	uid = 0
	note = why
	selected = -1
	installing = false
	install_pick = 0
	last = {}
	_again = false
	closed.emit(was, why)


static func _vehicle(snap: Snapshot, vehicle_uid: int) -> Snapshot.Vehicle:
	if snap == null or vehicle_uid == 0:
		return null
	for v in snap.vehicles:
		if v.uid == vehicle_uid:
			return v
	return null
