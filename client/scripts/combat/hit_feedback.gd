class_name HitFeedback
extends Node
## Hit confirmation from CDDA's events (contracts/events.md), never from the client's own flight: CDDA decides
## every hit. A `projectile` event shot by the player marks the creature it hit (`other`) for MARK_S; a `damage`
## event on a marked creature confirms a hit (HP lost, body part from `detail`), its `death` a kill.
## CDDA sends a shot's `damage` (and a death that happens at once) before that shot's `projectile` event, so
## damage and deaths on unmarked creatures wait RECENT_S: a player's projectile event claims those on its creature.
## Emits hit_confirmed (AimController's hit marker, VR, other UI) and plays a quiet generated tick (`sound`).
## Event fields are checked: bad uids, amounts or body parts skip the event.

signal hit_confirmed(uid: int, part: String, amount: int, killed: bool)

const MARK_S := 1.5            # a player's projectile marks the creature it hit this long
const RECENT_S := 0.5          # unclaimed damage / deaths wait this long for their projectile event
const MAX_MARKS := 64
const MAX_RECENT := 64
const MAX_EVENTS := 4096       # the bridge queue's cap; more in one batch are ignored
const MAX_UID := 1 << 53       # JSON numbers are doubles
const MAX_DETAIL := 1 << 20
const MAX_AMOUNT := 1 << 31    # int32 in the contract
const MAX_PART_LEN := 32
const PLAYER_UID := 1          # the contract's player uid, when the snapshot doesn't list the player
const HEAD_PARTS: Array[String] = ["head", "eyes"]
const TICK_RATE := 22050
const TICK_S := 0.05
const TICK_DB := -16.0         # quiet

var world: WorldView           # player uid (snapshot), body part names (id tables); may be null
var sound := true              # play the tick (VR may play its own instead)
var ticks := 0                 # ticks played (tests)
var _marks := {}               # uid -> {left (s), part, amount}
var _recent: Array[Dictionary] = []   # unclaimed: {kind, uid, part, amount, left}
var _player: AudioStreamPlayer
static var _tick: AudioStreamWAV


func _init(w: WorldView = null) -> void:
	name = "Hits"
	world = w
	_player = AudioStreamPlayer.new()
	_player.volume_db = TICK_DB
	add_child(_player)


## Events from the bridge; anything malformed is skipped.
func on_events(events: Array) -> void:
	var me := player_uid()
	for i in mini(events.size(), MAX_EVENTS):
		var e: Variant = events[i]
		if not e is Dictionary:
			continue
		var kind: Variant = (e as Dictionary).get("kind")
		if kind is String:
			match kind:
				"projectile":
					_on_projectile(e, me)
				"damage", "death":
					_on_hurt(kind, e, me)


func _process(delta: float) -> void:
	tick(delta)


## Ages the marks and the unclaimed events by `delta` seconds (tests call it directly).
func tick(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	for uid: int in _marks.keys():
		_marks[uid]["left"] -= delta
		if _marks[uid]["left"] <= 0.0:
			_marks.erase(uid)
	for i in range(_recent.size() - 1, -1, -1):
		_recent[i]["left"] -= delta
		if _recent[i]["left"] <= 0.0:
			_recent.remove_at(i)


func is_marked(uid: int) -> bool:
	return _marks.has(uid)


## The player's uid: the snapshot's player creature, else the contract's 1.
func player_uid() -> int:
	if world != null and world.snapshot != null:
		for c in world.snapshot.creatures:
			if c.kind == Snapshot.Creature.PLAYER:
				return c.uid
	return PLAYER_UID


func _on_projectile(e: Dictionary, me: int) -> void:
	var shooter := _uint(e.get("uid"), MAX_UID)
	var hit := _uint(e.get("other"), MAX_UID)
	if shooter <= 0 or hit <= 0 or hit == shooter or shooter != me:
		return
	if not _marks.has(hit):
		if _marks.size() >= MAX_MARKS:
			_marks.erase(_marks.keys()[0])   # the oldest
		_marks[hit] = {"part": "", "amount": 0}
	_marks[hit]["left"] = MARK_S
	var claimed: Array[Dictionary] = []
	for i in range(_recent.size() - 1, -1, -1):
		if _recent[i]["uid"] == hit:
			claimed.push_front(_recent[i])
			_recent.remove_at(i)
	for r in claimed:
		if _marks.has(hit):
			_confirm(r["kind"], hit, r["part"], r["amount"])


func _on_hurt(kind: String, e: Dictionary, me: int) -> void:
	var uid := _uint(e.get("uid"), MAX_UID)
	if uid <= 0 or uid == me:
		return
	var part := ""
	var amount := 0
	if kind == "damage":
		amount = _uint(e.get("amount", 0), MAX_AMOUNT)
		var detail := _uint(e["detail"], MAX_DETAIL) if e.has("detail") else 0
		if amount < 0 or detail < 0:
			return
		part = _part_name(detail) if e.has("detail") else ""
	if _marks.has(uid):
		_confirm(kind, uid, part, amount)
		return
	if _recent.size() >= MAX_RECENT:
		_recent.pop_front()
	_recent.append({"kind": kind, "uid": uid, "part": part, "amount": amount, "left": RECENT_S})


func _confirm(kind: String, uid: int, part: String, amount: int) -> void:
	var m: Dictionary = _marks[uid]
	if kind == "death":
		_marks.erase(uid)
		for i in range(_recent.size() - 1, -1, -1):
			if _recent[i]["uid"] == uid:
				_recent.remove_at(i)
		hit_confirmed.emit(uid, str(m["part"]), int(m["amount"]), true)
	else:
		m["part"] = part
		m["amount"] = amount
		hit_confirmed.emit(uid, part, amount, false)
	_play_tick()


## A body part index (the damage event's `detail`) as its id, "" if unknown; at most MAX_PART_LEN characters.
func _part_name(index: int) -> String:
	if world == null or world.tables == null:
		return ""
	return world.tables.body_part_name(index).left(MAX_PART_LEN)


## A non-negative integer up to `hi` (ints or integral floats), else -1.
static func _uint(v: Variant, hi: int) -> int:
	if v is int:
		return v if v >= 0 and v <= hi else -1
	if v is float:
		var f: float = v
		if f == floorf(f) and f >= 0.0 and f <= hi:   # false for NaN and infinities
			return int(f)
	return -1


func _play_tick() -> void:
	if not sound:
		return
	ticks += 1
	if is_inside_tree():
		_player.stream = tick_stream()
		_player.play()


## The hit tick, made once: a short bright click, two sines under a fast decay.
static func tick_stream() -> AudioStreamWAV:
	if _tick != null:
		return _tick
	var n := int(TICK_RATE * TICK_S)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / TICK_RATE
		var env := exp(-t * 90.0) * minf(t * 4000.0, 1.0)
		var v := (0.6 * sin(TAU * 2600.0 * t) + 0.25 * sin(TAU * 4300.0 * t)) * env
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 30000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = TICK_RATE
	w.data = data
	_tick = w
	return w
