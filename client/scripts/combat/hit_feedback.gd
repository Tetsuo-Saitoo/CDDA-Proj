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
## Melee: CDDA sends a strike's `attack` event (`detail` 1: a hit) before its damage. Right after the player's hit
## on a creature, that creature's `damage` events whose source (`other`) is the player confirm it, and its `death`
## then is a kill; only `message` and `sound` events may come between. Anything else ends the strike: damage with
## another or no source (bleeding, fire), on another creature, any other event. A strike's damage is never also
## a shot's.
## Several creatures: a technique that strikes around hits the others before the main hit's damage comes, so
## every creature the player hits in one run of strike events waits for its own damage (at most MAX_RUN of them);
## the player's miss in between changes nothing, anyone else's attack ends the run.
## Techniques: the player's hit may name the technique CDDA used (`text`) and its family (`amount`, 0..MAX_FAMILY);
## technique_used passes the name on as one clean line of at most MAX_TECHNIQUE_LEN characters.
## swing_resolved follows every strike of the player at a creature, hit or miss, after its technique: whatever a
## listener kept for that swing (AimController's called technique) ends there.
## Emits hit_confirmed, and strike_confirmed too for a melee hit (AimController's hit marker, VR, other UI), and
## plays a quiet generated tick (`sound`).
## Event fields are checked: bad uids, amounts or body parts skip the event.

## `part`: the monster's weak point id when the damage event names one (`text`, e.g. "head", "eye", "leg"), else
## the body part id from `detail`; "" unknown.
signal hit_confirmed(uid: int, part: String, amount: int, killed: bool)
## Also sent, after hit_confirmed, when the hit was the player's melee strike (a stronger buzz in VR, say).
signal strike_confirmed(uid: int, part: String, amount: int, killed: bool)
## The player's melee hit on creature `uid` used a technique: its display name (plain, never empty) and its
## family (0 none, 1 strike, 2 down, 3 stun, 4 disarm, 5 push). Sent at the hit, before its damage confirms.
signal technique_used(uid: int, technique: String, family: int)
## The player's strike at creature `uid` is over: a hit (after its technique_used, when it has one) or a miss.
signal swing_resolved(uid: int, hit: bool)

const MAX_EVENTS := 4096       # the bridge queue's cap; more in one batch are ignored
const MAX_UID := 1 << 53       # JSON numbers are doubles
const MAX_DETAIL := 1 << 20
const MAX_AMOUNT := 1 << 31    # int32 in the contract
const MAX_PART_LEN := 32
const MAX_TECHNIQUE_LEN := 40  # characters of a technique's name
const MAX_FAMILY := 5          # the contract's technique families are 0..5
const MAX_RUN := 64            # creatures one run of strikes may hold; one more starts a new run
const PLAYER_UID := 1          # the contract's player uid, when the snapshot doesn't list the player
const HEAD_PARTS: Array[String] = ["head", "eyes", "eye"]   # body parts and monsters' weak points
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
	# the run of strike events going on: each creature the player's melee hit is on -> its last confirmed damage
	# ({} when none yet); empty: no strike going on
	var run := {}
	for i in mini(events.size(), MAX_EVENTS):
		var e: Variant = events[i]
		if not e is Dictionary:
			continue
		var kind: Variant = (e as Dictionary).get("kind")
		if not kind is String:
			continue
		match kind:
			"attack":
				_on_attack(e, me, run)
			"damage", "death":
				var h := _hurt(kind, e, me)
				if not h.is_empty() and _strike_hurt(e, h, me, run):
					continue   # the strike's, not a shot's
				run.clear()
				if not h.is_empty():
					pending.append(h)
			"message", "sound":
				pass   # a strike's own messages come between its attack and its damage
			"projectile":
				run.clear()
				_on_projectile(e, me, pending)
				pending.clear()
			_:
				run.clear()


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


## An attack event and the run of strikes (`run`, see on_events): the player's hit on a creature adds it to the
## run, or starts it again there, and tells its technique; the player's miss on a creature leaves the run as it
## is; anyone else's attack or a malformed one ends the run. A creature over MAX_RUN ends the run and starts a
## new one. Either way the player's strike at a creature ends with swing_resolved.
func _on_attack(e: Dictionary, me: int, run: Dictionary) -> void:
	var target := _struck(e, me)
	if target <= 0:
		run.clear()
		return
	if _uint(e.get("detail"), 1) != 1:
		swing_resolved.emit(target, false)
		return   # a miss
	if not run.has(target) and run.size() >= MAX_RUN:
		run.clear()
	run[target] = {}
	_technique(e, target)
	swing_resolved.emit(target, true)


## A hit's technique: emits technique_used when the event's `text` gives a name (one plain line, no colour tags,
## control or hidden direction characters, at most MAX_TECHNIQUE_LEN characters). The family is `amount` when it
## is a whole number 0..MAX_FAMILY, else 0.
func _technique(e: Dictionary, uid: int) -> void:
	var technique := Snapshot.plain_text(e.get("text"), MAX_TECHNIQUE_LEN)
	if technique.is_empty():
		return
	technique_used.emit(uid, technique, maxi(_uint(e.get("amount"), MAX_FAMILY), 0))


## A damage or death event `h` (_hurt) on a creature of the run: damage whose source (`other`) is the player
## confirms the strike and is kept as that creature's last; a death after confirmed damage is the kill and takes
## the creature out of the run. False when the event isn't the run's (another creature, another or no source, a
## death with no confirmed damage).
func _strike_hurt(e: Dictionary, h: Dictionary, me: int, run: Dictionary) -> bool:
	var uid: int = h["uid"]
	if not run.has(uid):
		return false
	if h["kind"] == "death":
		var last: Dictionary = run[uid]
		if last.is_empty():
			return false
		run.erase(uid)
		_confirm(uid, last["part"], last["amount"], true, true)
		return true
	if _uint(e.get("other"), MAX_UID) != me:
		return false
	run[uid] = h
	_confirm(uid, h["part"], h["amount"], false, true)
	return true


## An attack event: the creature the player struck at (`other`), hit or missed (`detail` 1 or 0); 0 for anyone
## else's attack, bad uids, the player as the target or another `detail`.
func _struck(e: Dictionary, me: int) -> int:
	var attacker := _uint(e.get("uid"), MAX_UID)
	var target := _uint(e.get("other"), MAX_UID)
	if attacker <= 0 or attacker != me or target <= 0 or target == me or _uint(e.get("detail"), 1) < 0:
		return 0
	return target


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
		part = weak_point(e.get("text"))
		if part.is_empty():
			part = _part_name(detail) if e.has("detail") else ""
	return {"kind": kind, "uid": uid, "part": part, "amount": amount}


func _confirm(uid: int, part: String, amount: int, killed: bool, strike := false) -> void:
	hit_confirmed.emit(uid, part, amount, killed)
	if strike:
		strike_confirmed.emit(uid, part, amount, killed)
	_play_tick()


## A damage event's `text`: the monster's weak point id CDDA's hit landed on, when it is one (an ASCII identifier
## of at most MAX_PART_LEN characters); "" for none or anything else.
static func weak_point(v: Variant) -> String:
	if not v is String:
		return ""
	var s: String = v
	return s if s.length() <= MAX_PART_LEN and s.is_valid_ascii_identifier() else ""


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
