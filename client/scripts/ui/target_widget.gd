class_name TargetRequestWidget
extends RequestWidget
## `target` requests (look_around, target_ui): a cursor square, the creatures in view and CDDA's actions.
## Candidates are named from the snapshot when `world_state` gives one (name, hostile / friendly, health in
## words; NPCs are "someone": the snapshot has no NPC names).
## Keys: arrows / numpad move the cursor (relative to the screen), < > change level, Tab / Shift+Tab next /
## previous creature, Enter = the main action (FIRE, else CONFIRM or SELECT, else the first), Space checks
## the square (CDDA asks again with a new status), 1-9 press an action, Esc cancels. Mouse: click a creature,
## then an action. `set_cursor` lets the 3D view pick a square (block E2).
## R (fire mode): quick reload = leave aiming, reload the wielded gun, aim again.
## Answer: `pos` (absolute square) with or without `action`.

const REACH := 132          # the cursor stays within a bubble's width of the origin
const MAX_ROWS := 64
const MAX_CANDIDATES := 256
const COORD_LIMIT := (1 << 28) - REACH - 1
const PRIMARY := ["FIRE", "CONFIRM", "SELECT"]
const RELOAD_THEN := ["reload_weapon", "fire"]
const STATUS_TEXT := {
	"bad_target": "No valid target there", "out_of_ammo": "Out of ammo", "out_of_range": "Out of range",
}
const MAX_NAME_CHARS := 48
## hp_frac (0..255) at or above each step -> words, as CDDA describes a monster's health.
const HEALTH_WORDS := [[255, "uninjured"], [204, "lightly injured"], [153, "moderately injured"],
		[77, "heavily injured"], [26, "severely injured"], [0, "nearly dead"]]
const HOSTILE_TEXT := Color(1.0, 0.62, 0.55)
const FRIENDLY_TEXT := Color(0.6, 1.0, 0.65)

var mode := ""
var origin := Vector3i.ZERO
var cursor := Vector3i.ZERO
var range_limit := 0
var candidates: Array[Vector3i] = []   # nearest first
var actions := PackedStringArray()
var action_buttons: Array[Button] = []
var candidate_buttons: Array[Button] = []
var _cursor_label: RichTextLabel
var _candidate := -1
## Returns [Snapshot, IdTables] as they are now (either may be null); RequestUI passes main.gd's.
var world_state := Callable()


func setup(req: Dictionary) -> void:
	super(req)
	mode = str_of(req, "mode", 32)
	var o := vec_of(req, "origin")
	origin = Vector3i(clampi(o.x, -COORD_LIMIT, COORD_LIMIT), clampi(o.y, -COORD_LIMIT, COORD_LIMIT),
			clampi(o.z, -10, 10))
	cursor = _clamp(vec_of(req, "cursor"))
	range_limit = int_of(req, "range", 0, 0, 1000000)
	actions = actions_of(req)
	var list: Variant = req.get("candidates")
	if list is Array:
		for c: Variant in list:
			if candidates.size() >= MAX_CANDIDATES:
				break
			if c is Vector3i and c == _clamp(c) and not candidates.has(c):
				candidates.append(c)
	candidates.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return _dist(a) < _dist(b))

	if CddaText.plain(str_of(req, "title")).strip_edges().is_empty():
		var t := add_rich("<color_white>%s</color>" % (mode.capitalize() if not mode.is_empty() else "Target"))
		t.add_theme_font_size_override("normal_font_size", 18)
	add_header(req)
	var status := str_of(req, "status", 64)
	if not status.is_empty():
		add_rich("<color_light_red>%s</color>" % STATUS_TEXT.get(status, status))
	_cursor_label = add_rich("")
	if not candidates.is_empty():
		var l := Label.new()
		l.text = "In view (Tab):"
		add_child(l)
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.custom_minimum_size.y = minf(candidates.size(), 5) * 36.0
		add_child(scroll)
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(box)
		var state := _world_state()
		for i in mini(candidates.size(), MAX_ROWS):
			var d := candidates[i] - origin
			var text := "%s   (%d)" % [offset_text(d), _dist(candidates[i])]
			var c: Snapshot.Creature = state[0].creature_at(candidates[i]) if state[0] != null else null
			if c != null:
				text = "%s   %s" % [creature_text(c, state[1]), text]
			var b := add_button(text, pick_candidate.bind(i), box)   # Button text is plain: no markup
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			if c != null and (c.is_hostile() or c.attitude == Snapshot.Creature.FRIENDLY):
				var col := HOSTILE_TEXT if c.is_hostile() else FRIENDLY_TEXT
				for k: String in ["font_color", "font_hover_color", "font_pressed_color"]:
					b.add_theme_color_override(k, col)
			candidate_buttons.append(b)
	var bar := HFlowContainer.new()
	add_child(bar)
	for i in actions.size():
		var label := action_label(actions[i])
		if i < 9:
			label = "%d  %s" % [i + 1, label]
		action_buttons.append(add_button(label, press.bind(i), bar))
	if mode == "fire":
		add_button("Reload (R)", reload, bar)
	add_button("Check square (Space)", check, bar)
	if allow_cancel:
		add_button("Cancel (Esc)", cancel, bar)
	add_hint("Arrows / numpad: cursor  < > level  Tab next  Enter %s  Space check%s" % [
			action_label(actions[primary_index()]) if primary_index() >= 0 else "check",
			"  Esc cancel" if allow_cancel else ""])
	_update_cursor()


## Moves the cursor (clamped near the origin) without answering.
func set_cursor(p: Vector3i) -> void:
	cursor = _clamp(p)
	_candidate = candidates.find(cursor)
	_update_cursor()


func move_cursor(step: Vector3i) -> void:
	set_cursor(cursor + step)


func pick_candidate(i: int) -> void:
	if i >= 0 and i < candidates.size():
		set_cursor(candidates[i])


func next_candidate(delta: int) -> void:
	if not candidates.is_empty():
		pick_candidate(wrapi((_candidate if _candidate >= 0 else (-1 if delta > 0 else 0)) + delta, 0,
				candidates.size()))


func press(i: int) -> void:
	if i >= 0 and i < actions.size():
		send({"pos": cursor, "action": actions[i]})


## Shoots (or throws, casts...) at the cursor square: the primary action, else checks the square. The 3D view's
## crosshair and fire key use it (AimController).
func fire() -> void:
	var p := primary_index()
	if p >= 0:
		press(p)
	else:
		check()


## Quick reload (fire mode): cancels aiming; RequestUI then queues reload_weapon and fire, so CDDA reloads
## (asking which ammo if it must) and opens aiming again.
func reload() -> void:
	if mode == "fire" and not done:
		send({"cancel": true, "then": PackedStringArray(RELOAD_THEN)})


## Fires a shot the client flew itself (BulletPhysics): CDDA follows `shot` (end square, creature, part)
## instead of rolling. `pos` is where it went; the action is the primary one (FIRE).
func fire_shot(pos: Vector3i, shot: Dictionary) -> void:
	var p := primary_index()
	if p < 0 or done:
		return
	cursor = _clamp(pos)
	send({"pos": cursor, "action": actions[p], "shot": shot})


## True for modes that shoot or throw at something (the crosshair follows the view in these).
static func is_attack_mode(m: String) -> bool:
	return m in ["fire", "throw", "throw_blind", "turret_manual", "reach", "spell"]


## Sends the cursor square without an action; CDDA moves its cursor there and asks again.
func check() -> void:
	send({"pos": cursor})


func primary_index() -> int:
	for a: String in PRIMARY:
		if actions.has(a):
			return actions.find(a)
	return 0 if not actions.is_empty() else -1


## "zombie (hostile, lightly injured)": the creature's name (monsters from the id tables, NPCs "someone"), how
## it stands to the player, and its health in words.
static func creature_text(c: Snapshot.Creature, tables: IdTables) -> String:
	var who := "someone"
	if c.kind == Snapshot.Creature.MONSTER:
		var d: IdTables.Def = tables.def_at("mtype", c.type) if tables != null else null
		who = plain_name(d.name) if d != null else ""
		if who.is_empty():
			who = "creature"
	var notes := PackedStringArray()
	if c.is_hostile():
		notes.append("hostile")
	elif c.attitude == Snapshot.Creature.FRIENDLY:
		notes.append("friendly")
	elif c.attitude == Snapshot.Creature.NEUTRAL:
		notes.append("neutral")
	notes.append(health_words(c.hp_frac))
	return "%s (%s)" % [who, ", ".join(notes)]


static func health_words(hp_frac: int) -> String:
	for step: Array in HEALTH_WORDS:
		if hp_frac >= step[0]:
			return step[1]
	return HEALTH_WORDS[-1][1]


## A name for one line of plain text: control characters become spaces, at most MAX_NAME_CHARS.
static func plain_name(s: String) -> String:
	var out := PackedStringArray()
	for ch in s.left(MAX_NAME_CHARS):
		out.append(ch if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127 else " ")
	return "".join(out).strip_edges()


## "3 E, 2 N, 1 up" for a relative square (CDDA's y points south).
static func offset_text(d: Vector3i) -> String:
	var parts := PackedStringArray()
	if d.y != 0:
		parts.append("%d %s" % [absi(d.y), "N" if d.y < 0 else "S"])
	if d.x != 0:
		parts.append("%d %s" % [absi(d.x), "E" if d.x > 0 else "W"])
	if d.z != 0:
		parts.append("%d %s" % [absi(d.z), "up" if d.z > 0 else "down"])
	return ", ".join(parts) if not parts.is_empty() else "here"


func handle_input(event: InputEvent) -> bool:
	var key := key_of(event, true)
	if key == KEY_NONE:
		return false
	var k := event as InputEventKey
	var c := char_of(event)
	if c == "<" or c == ">":
		move_cursor(Vector3i(0, 0, 1 if c == "<" else -1))
	elif MOVE_KEYS.has(key):
		var s := map_step(MOVE_KEYS[key])
		move_cursor(Vector3i(s.x, s.y, 0))
	elif key == KEY_TAB:
		if not k.echo:
			next_candidate(-1 if k.shift_pressed else 1)
	elif key == KEY_ENTER or key == KEY_KP_ENTER:
		if not k.echo:
			fire()
	elif key == KEY_R and mode == "fire":
		if not k.echo:
			reload()
	elif key == KEY_SPACE:
		if not k.echo:
			check()
	elif key == KEY_ESCAPE:
		if not k.echo:
			cancel()
	elif key >= KEY_1 and key <= KEY_9:
		if not k.echo:
			press(key - KEY_1)
	else:
		return false
	return true


## [Snapshot or null, IdTables or null] from `world_state`; anything else it returns counts as none.
func _world_state() -> Array:
	var out := [null, null]
	if not world_state.is_valid():
		return out
	var s: Variant = world_state.call()
	if s is Array and (s as Array).size() == 2:
		out[0] = s[0] if s[0] is Snapshot else null
		out[1] = s[1] if s[1] is IdTables else null
	return out


func _clamp(p: Vector3i) -> Vector3i:
	return Vector3i(clampi(p.x, origin.x - REACH, origin.x + REACH), clampi(p.y, origin.y - REACH, origin.y + REACH),
			clampi(p.z, -10, 10))


func _dist(p: Vector3i) -> int:
	return maxi(absi(p.x - origin.x), absi(p.y - origin.y))


func _update_cursor() -> void:
	var dist := _dist(cursor)
	var r := ""
	if range_limit > 0:
		r = " / range %d" % range_limit
		if dist > range_limit:
			r += " <color_light_red>(out of range)</color>"
	_cursor_label.text = CddaText.to_bbcode("Cursor: %s, distance %d%s" % [offset_text(cursor - origin), dist, r])
	for i in candidate_buttons.size():
		mark(candidate_buttons[i], candidates[i] == cursor)
