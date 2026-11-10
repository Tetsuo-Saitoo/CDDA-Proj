class_name HitFeedback
extends Node
## Hit confirmation from CDDA's events (contracts/events.md), never from the client's own flight: CDDA decides
## every hit, and only the player's own shots count.
## CDDA sends a shot's `damage` (and a death that happens at once) before that shot's `projectile` event, in the
## same drained batch. So a `projectile` event shot by the player that names the creature it hit (`other`)
## confirms the damage (HP lost, body part from `detail`) and death events on that creature that came before it
## in the same on_events() batch, after the batch start or the previous projectile event (anyone's: damage before
## an ally's projectile event is the ally's). Damage in another batch, after the projectile event, on another
## creature, or before someone else's projectile event (an ally's shot, bleeding, fire) is never credited.
## Emits hit_confirmed (AimController's hit marker, VR, other UI) and plays a quiet generated tick (`sound`).
## Event fields are checked: bad uids, amounts or body parts skip the event.

signal hit_confirmed(uid: int, part: String, amount: int, killed: bool)

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
var _player: AudioStreamPlayer
static var _tick: AudioStreamWAV


func _init(w: WorldView = null) -> void:
	name = "Hits"
	world = w
	_player = AudioStreamPlayer.new()
	_player.volume_db = TICK_DB
	add_child(_player)


## One drained batch of events from the bridge; anything malformed is skipped. Nothing carries over to the next
## batch.
func on_events(events: Array) -> void:
	var me := player_uid()
	var pending: Array[Dictionary] = []   # damage / deaths since the batch start or the last projectile event
	for i in mini(events.size(), MAX_EVENTS):
		var e: Variant = events[i]
		if not e is Dictionary:
			continue
		var kind: Variant = (e as Dictionary).get("kind")
		if not kind is String:
			continue
		match kind:
			"projectile":
				_on_projectile(e, me, pending)
				pending.clear()
			"damage", "death":
				var h := _hurt(kind, e, me)
				if not h.is_empty():
					pending.append(h)


## The player's uid: the snapshot's player creature, else the contract's 1.
func player_uid() -> int:
	if world != null and world.snapshot != null:
		for c in world.snapshot.creatures:
			if c.kind == Snapshot.Creature.PLAYER:
				return c.uid
	return PLAYER_UID


## A projectile event: when the player shot it into a creature, confirms that creature's `pending` damage and
## death, in order.
func _on_projectile(e: Dictionary, me: int, pending: Array[Dictionary]) -> void:
	var shooter := _uint(e.get("uid"), MAX_UID)
	var hit := _uint(e.get("other"), MAX_UID)
	if shooter <= 0 or shooter != me or hit <= 0 or hit == shooter:
		return
	var part := ""
	var amount := 0
	for h in pending:
		if h["uid"] != hit:
			continue
		if h["kind"] == "death":
			_confirm(hit, part, amount, true)   # the kill shows the last hit's part and amount
			return
		part = h["part"]
		amount = h["amount"]
		_confirm(hit, part, amount, false)


## A damage or death event as {kind, uid, part, amount}, or {} when it is malformed or on the player.
func _hurt(kind: String, e: Dictionary, me: int) -> Dictionary:
	var uid := _uint(e.get("uid"), MAX_UID)
	if uid <= 0 or uid == me:
		return {}
	var part := ""
	var amount := 0
	if kind == "damage":
		amount = _uint(e.get("amount", 0), MAX_AMOUNT)
		var detail := _uint(e["detail"], MAX_DETAIL) if e.has("detail") else 0
		if amount < 0 or detail < 0:
			return {}
		part = _part_name(detail) if e.has("detail") else ""
	return {"kind": kind, "uid": uid, "part": part, "amount": amount}


func _confirm(uid: int, part: String, amount: int, killed: bool) -> void:
	hit_confirmed.emit(uid, part, amount, killed)
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
