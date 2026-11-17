extends SceneTree
## Headless combat in the test range through main and the real DLL, monsters frozen, at noon:
##  1. Q wields the kit's Glock (CDDA's wield list, answered in RequestUI), F aims at a zombie three squares ahead
##     and F again fires at the screen centre: the crosshair flies the shot (one kick), a projectile leaves the
##     player, the gun has a round less.
##  2. R reloads it (CDDA's magazine list answered with its first entry when asked): another magazine goes in
##     (the kit's spares hold 10, so the count changes rather than rises).
##  3. A wooden spear at the feet is wielded and the main hand strikes a zombie a knight's move off, aimed at its
##     square (`fp3d_attack_main_aim_at` by queue_action_at): the swing request is answered and the strike lands or
##     misses on that zombie.
##  4. The machete is wielded and the main hand strikes the zombie next to you, aimed at its head (a stun call):
##     each aimed swing is answered and resolved; the techniques CDDA used are listed (none expected: the machete
##     has only a block technique, and the range has no skill cheat for the others; the sim test covers them).
##  5. A live grenade on a zombie's square seven squares ahead goes off after its countdown (turns pass with
##     "pause"): an `explosion` event, ExplosionView's blast and a shake, the zombie's death, its body lying there
##     (CreatureView) and its blood on the ground (GoreView). The player is invincible (the range's cheat) meanwhile:
##     CDDA's shrapnel kills in the open out to some 30 squares. Fire fields aren't tried: the range's only explosive
##     with a countdown is the plain grenade.
## Strikes go through main's own code (AimController.strike_action, main._queue_act) with the crosshair at the
## screen centre: headless has no captured mouse. A misfire isn't tried: nothing in the range fouls a gun (the sim
## test covers it). Uses this run's own CDDA folder, never the player's saves.
## Needs the DLL (build target fp3d-cdda) and the game data (../cdda, or --cdda=<folder>). ~3 min. From the repo
## root:
##   godot --headless --path client --script res://tests/combat_live_test.gd -- --live
## Exit code 0 = all passed.

const Main := preload("res://scripts/main.gd")
const TestDir := preload("res://tests/test_dir.gd")
const BOOT_TIMEOUT_MS := 300000
const OP_TIMEOUT_MS := 90000
const ASK_TIMEOUT_MS := 15000
const CHEST_M := 1.2        # aim this high over a creature's square (its body)
const HEAD_M := 1.6         # and this high for its head
const MAX_EVENTS := 4096    # events kept between _clear()s

var _failed := 0
var _main: Main
var _live: LiveSession
var _cp: CheatPanel
var _done := {}       # op id -> error ("" = done), from LiveSession.range_done
var _answered := 0
var _events: Array[Dictionary] = []
var _shots := 0       # AimController.shot_went
var _swings: Array = []        # [uid, hit] per HitFeedback.swing_resolved
var _techniques: Array = []    # technique names per HitFeedback.technique_used
var _blast_live := 0           # ExplosionView.live_count() at the end of a frame that brought an explosion event
var _blast_shake := 0.0        # and its shake_strength()


func _initialize() -> void:
	_run()


func _run() -> void:
	if not "--live" in OS.get_cmdline_user_args():
		_check(false, "run with -- --live (main takes its mode from the command line)")
		_finish()
		return
	_check(LiveSession.test_range_available(), "the bridge has the test range")
	if _failed > 0:
		_finish()
		return
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	_main.cdda_user_dir = TestDir.global("cdda-combat")
	root.add_child(_main)
	await process_frame
	_live = _main.live
	_cp = _main.cheat_panel
	_live.range_done.connect(func(id: int, err: String) -> void: _done[id] = err)
	_live.events_arrived.connect(_on_events)
	_main.aim.shot_went.connect(func() -> void: _shots += 1)
	_main.aim.hits.swing_resolved.connect(func(uid: int, hit: bool) -> void: _swings.append([uid, hit]))
	_main.aim.hits.technique_used.connect(func(_uid: int, t: String, _f: int) -> void: _techniques.append(t))
	var button := _find_button(_main.main_menu, "Test range") if _main.main_menu != null else null
	_check(button != null, "the main menu shows the Test range button")
	if button == null:
		_finish()
		return
	button.pressed.emit()
	var t0 := Time.get_ticks_msec()
	var up := func() -> bool: return (_live.state == "running" and _main.world.snapshot != null
			and _cp.tables != null)
	_check(await _until(up, BOOT_TIMEOUT_MS, true), "the range runs (%.0f s, state %s %s)"
			% [(Time.get_ticks_msec() - t0) / 1000.0, _live.state, _live.error])
	if _live.state != "running":
		_finish()
		return
	if _main.view_mode != "first":
		_main._set_view("first")   # the eyes' camera aims (not saved: the player's view setting stays)
	var kits := _live.kits_given()
	_check(_live.give_test_kit(), "test kit asked for")
	_live.queue_action("pause")
	var kit_in := func() -> bool: return _live.kits_given() > kits
	_check(await _until(kit_in, OP_TIMEOUT_MS, true), "the test kit arrived")
	if not _live.range_info().get("ai_frozen", false):
		_check(await _op(func() -> void: _cp.set_frozen(true), "Freeze") == "", "monsters frozen")
	_cp.hour.value = 12
	_check(await _op(_cp.set_time, "Time 12:00") == "", "time set to noon")
	if _main.key_menu.visible:
		_main.key_menu.close()
	if _live.state == "running":
		await _gun_live()
	if _live.state == "running":
		await _reach_live()
	if _live.state == "running":
		await _melee_live()
	if _live.state == "running":
		await _explosion_live()
	if _live.state != "running":
		_check(false, "the game kept running (%s %s)" % [_live.state, _live.error])
	await _stop()
	_finish()


## 1 and 2: wield the Glock, fire at a zombie three squares ahead, reload.
func _gun_live() -> void:
	if not await _wield("glock", "glock_19"):
		return
	var gun := func() -> Dictionary: return _main.world.snapshot.player_gun
	var rounds0: int = gun.call().get("rounds", -1)
	var target := _ahead(3, 0)
	if not await _spawn_zombie(target):
		return
	await _face(target, CHEST_M)
	_clear()
	var shots0 := _shots
	root.push_input(_key_of(&"cdda_fire"))
	var aiming := func() -> bool: return _main.request_ui.target_widget() != null
	if not await _until(aiming, ASK_TIMEOUT_MS, false):
		_check(false, "F: CDDA asks for a target (%s)" % [_live.request])
		return
	root.push_input(_key_of(&"cdda_fire"))   # aiming: F fires at the screen centre
	var fired := func() -> bool: return _shots > shots0 and gun.call().get("rounds", -1) < rounds0
	var ok := await _until(fired, OP_TIMEOUT_MS, false)
	await _until(aiming, 3000, false)   # CDDA aims again after a shot (its "aim after firing" option)
	if aiming.call():
		root.push_input(_esc_key())   # Esc stops aiming
	ok = await _until(_in_loop, ASK_TIMEOUT_MS, false) and ok
	var me := _main.aim.hits.player_uid()
	var flew := _events.filter(func(e: Dictionary) -> bool:
			return e.get("kind") == "projectile" and int(e.get("uid", 0)) == me)
	var hurt := _events.filter(func(e: Dictionary) -> bool:
			return e.get("kind") == "damage" and int(e.get("uid", 0)) != me)
	_check(ok and _shots == shots0 + 1 and flew.size() == 1,
			"F, F: the Glock fires at the zombie ahead (one kick, %d projectile(s) from the player, rounds %d -> %d, %s)"
			% [flew.size(), rounds0, gun.call().get("rounds", -1), "hit" if not hurt.is_empty() else "missed"])
	var rounds1: int = gun.call().get("rounds", -1)
	root.push_input(_key_of(&"cdda_reload"))
	var asked_or_done := func() -> bool:
		return (_main.request_ui.is_showing() and _main.request_ui.widget is ListRequestWidget) \
				or gun.call().get("rounds", -1) != rounds1
	await _until(asked_or_done, ASK_TIMEOUT_MS, false)
	var listed := _main.request_ui.is_showing() and _main.request_ui.widget is ListRequestWidget
	if listed:
		_answered = int(_live.request.get("id", 0))   # answered by Enter, not by _answer_prompt
		root.push_input(_enter_key())   # the first magazine CDDA offers
	var reloaded := func() -> bool: return gun.call().get("rounds", -1) not in [rounds1, 0, -1] and _in_loop()
	_check(await _until(reloaded, OP_TIMEOUT_MS, true), "R: the Glock reloads (%s, rounds %d -> %d)"
			% ["CDDA asked which magazine" if listed else "no list", rounds1, gun.call().get("rounds", -1)])


## 3: a wooden spear strikes a zombie a knight's move off at its square.
func _reach_live() -> void:
	var idx := _cp.tables.index_of("itype", "spear_wood")
	if idx < 0:
		print("  (reach not tried: no spear_wood in this game's data)")
		return
	var me: Vector3i = _main.world.snapshot.player_pos
	var id := _live.range_spawn_item(idx, 1, me)
	_check(await _op_id(id, "Spawn spear_wood") == "", "a wooden spear at the feet")
	if not await _wield("spear", "spear_wood"):
		return
	var target := _ahead(2, 1)
	if not await _spawn_zombie(target):
		target = _ahead(2, -1)
		if not await _spawn_zombie(target):
			return
	var z := _main.world.snapshot.creature_at(target)
	var n := _swings.size()
	var act := await _strike_at(target, CHEST_M)
	_check(act == AimController.AT_ACTION, "spear: the crosshair on the zombie a knight's move off picks a strike at its square (%s)" % act)
	if act != AimController.AT_ACTION:
		return
	var resolved: Variant = await _resolved_on(z.uid if z != null else 0, n)
	_check(resolved != null, "spear: the aimed swing is answered and the strike resolves on that zombie (%s, %d HP lost)"
			% ["hit" if resolved != null and resolved[1] else "miss", _hp_lost(z.uid if z != null else 0)])


## 4: the machete strikes the zombie next to you, aimed at its head; the techniques CDDA used are listed.
func _melee_live() -> void:
	if not await _wield("machete", "machete"):
		return
	var target := _ahead(1, 0)
	if _main.world.snapshot.creature_at(target) == null and not await _spawn_zombie(target):
		return
	var tech0 := _techniques.size()
	var aimed := 0
	var resolved := 0
	var lost := 0
	for i in 3:
		var z := _main.world.snapshot.creature_at(target)
		if z == null:
			break   # dead
		var n := _swings.size()
		var act := await _strike_at(target, HEAD_M)
		if act.contains("_aim_"):
			aimed += 1
		if await _resolved_on(z.uid, n) != null:
			resolved += 1
		lost += _hp_lost(z.uid)
	_check(aimed > 0 and resolved == aimed,
			"machete: aimed strikes at the head next to you are answered and resolve (%d aimed, %d resolved, %d HP lost)"
			% [aimed, resolved, lost])
	print("    techniques used: %s" % [_techniques.slice(tech0)])


## 5: a live grenade on a zombie's square seven squares ahead: the blast, the death, the body and its blood.
func _explosion_live() -> void:
	var gid := _cp.tables.index_of("itype", "grenade_act")
	if gid < 0:
		print("  (explosions not tried: no grenade_act in this game's data)")
		return
	var target := Vector3i.ZERO
	var placed := false
	for off: Vector2i in [Vector2i(7, 0), Vector2i(6, 1), Vector2i(6, -1), Vector2i(7, 2), Vector2i(7, -2),
			Vector2i(6, 0), Vector2i(5, 2), Vector2i(5, -2)]:
		target = _ahead(off.x, off.y)
		if _main.world.snapshot.creature_at(target) == null and await _spawn_zombie(target):
			placed = true
			break
	_check(placed, "a zombie five to seven squares ahead for the grenade (%s)" % target)
	if not placed:
		return
	# CDDA's shrapnel kills in the open out to some 30 squares: the player is invincible while the grenade goes off.
	var shielded := _live.set_cheat("invincible", true)
	if shielded:
		shielded = await _pass_turn() and bool(_live.cheats().get("invincible", false))
	_check(shielded, "the player is invincible for the blast (the range's cheat)")
	if not shielded:
		return
	var z := _main.world.snapshot.creature_at(target)
	var zuid := z.uid if z != null else 0
	var bodies0 := _main.creature_view.corpse_count()
	var gore0 := _main.gore.count()
	_clear()
	_blast_live = 0
	_blast_shake = 0.0
	_check(await _op_id(_live.range_spawn_item(gid, 1, target), "Spawn grenade_act") == "",
			"a live grenade on the zombie's square")
	var of_kind := func(kind: String) -> Array:
		return _events.filter(func(e: Dictionary) -> bool: return e.get("kind") == kind)
	var turns := 0
	var t0 := _main.world.snapshot.turn
	while of_kind.call("explosion").is_empty() and turns < 12 and _live.state == "running":
		if not await _pass_turn():
			print("    (a turn didn't pass: turn %d)" % _main.world.snapshot.turn)
		turns += 1
	print("    turns %d -> %d" % [t0, _main.world.snapshot.turn])
	await process_frame   # the deferred note of the blast
	var blasts: Array = of_kind.call("explosion")
	var b: Dictionary = blasts[0] if not blasts.is_empty() else {}
	var at: Variant = b.get("pos")
	_check(not blasts.is_empty() and str(b.get("text")) == "blast" and _blast_live > 0 and _blast_shake > 0.0,
			"it goes off after %d turn(s): a blast event at %s, ExplosionView draws it (%d live) and shakes the view (%.2f)"
			% [turns, at, _blast_live, _blast_shake])
	var died := func() -> bool:
		return of_kind.call("death").any(func(e: Dictionary) -> bool: return int(e.get("uid", 0)) == zuid)
	_check(zuid != 0 and await _until(died, OP_TIMEOUT_MS, false), "the blast kills the zombie (a death event)")
	var body := func() -> bool: return _main.creature_view.corpse_count() > bodies0
	# No turn passes meanwhile: the body must show once the death fall ends, not on the next snapshot.
	_check(await _until(body, OP_TIMEOUT_MS, false),
			"its body lies there (CreatureView: %d -> %d bodies; %d corpse pile(s) near in the snapshot)"
			% [bodies0, _main.creature_view.corpse_count(), _corpse_piles_near(target, 3)])
	var bled := func() -> bool: return _main.gore.count() > gore0
	_check(await _until(bled, ASK_TIMEOUT_MS, false), "its blood is on the ground (GoreView: %d -> %d)"
			% [gore0, _main.gore.count()])
	var hurt: Array = of_kind.call("damage").filter(func(e: Dictionary) -> bool:
			return int(e.get("uid", 0)) == _main.aim.hits.player_uid())
	print("    the player took %d hit(s) from seven squares, unhurt (invincible)" % hurt.size())
	_live.set_cheat("invincible", false)


## Piles holding a corpse within `r` squares of `sq` (same level) in the current snapshot.
func _corpse_piles_near(sq: Vector3i, r: int) -> int:
	var n := 0
	for sm: Snapshot.Submap in _main.world.snapshot.submaps.values():
		var base := CddaCoords.sm_to_ms(sm.pos)
		for j in range(0, sm.items.size() - Snapshot.PILE_STRIDE + 1, Snapshot.PILE_STRIDE):
			var t := sm.items[j]
			var p := base + Vector3i(t % CddaCoords.SEEX, t / CddaCoords.SEEX, 0)
			var near := p.z == sq.z and absi(p.x - sq.x) <= r and absi(p.y - sq.y) <= r
			if near and sm.items[j + Snapshot.PILE_CORPSE] != 0:
				n += 1
	return n


## Faces `sq` (the first-person camera looks at it, `up` metres over the ground), then picks the main hand's strike
## as main does for the strike key with the crosshair at the screen centre, and queues it. The action, "" if none.
func _strike_at(sq: Vector3i, up: float) -> String:
	await _until(_in_loop, ASK_TIMEOUT_MS, false)
	await _face(sq, up)
	var cam := _main.get_viewport().get_camera_3d()
	var centre := _main.get_viewport().get_visible_rect().size / 2.0
	var facing: String = Main.OCT_ACTIONS[_main._octant(Vector2(0, 1))]
	var act := _main.aim.strike_action("main", cam, centre, true, _main.world.snapshot.player_pos, facing)
	_clear()
	_main._queue_act(act)
	return act


## The first swing_resolved on `uid` ([uid, hit]) from swing number `n` on, or null when none comes in time.
func _resolved_on(uid: int, n: int) -> Variant:
	var got := func() -> bool: return _swings.slice(n).any(func(s: Array) -> bool: return s[0] == uid)
	if not await _until(got, OP_TIMEOUT_MS, false):
		return null
	for s: Array in _swings.slice(n):
		if s[0] == uid:
			return s
	return null


## The square `ahead` steps forward and `right` steps right of the player, as the view faces now.
func _ahead(ahead: int, right: int) -> Vector3i:
	var f := _main._screen_step(Vector2(0, 1))
	var r := _main._screen_step(Vector2(1, 0))
	var s := f * ahead + r * right
	return _main.world.snapshot.player_pos + Vector3i(s.x, s.y, 0)


## Points the first-person camera at `sq`, `up` metres over the ground.
func _face(sq: Vector3i, up: float) -> void:
	var cam := _main.get_viewport().get_camera_3d()
	var d := _main.world.coords.ms_center_to_world(sq) + Vector3(0, up, 0) - cam.global_position
	_main.fp.set_look(atan2(-d.x, -d.z), atan2(d.y, Vector2(d.x, d.z).length()))
	await process_frame
	await process_frame


func _spawn_zombie(sq: Vector3i) -> bool:
	var err := await _op_id(_live.range_spawn_monster("mon_zombie", sq), "Spawn mon_zombie at %s" % sq)
	if err != "":
		print("  (no zombie at %s: %s)" % [sq, err])
		return false
	var there := func() -> bool: return _main.world.snapshot.creature_at(sq) != null
	_check(await _until(there, OP_TIMEOUT_MS, true), "a zombie stands at %s" % sq)
	return there.call()


## Q, then the item whose list name holds `name` (CDDA's wield list in RequestUI), Enter; true once the main hand
## holds `itype`.
func _wield(name: String, itype: String) -> bool:
	var idx := _cp.tables.index_of("itype", itype)
	var held := func() -> bool:
		var r: Variant = _main.hud_data.held.get("main")
		return r is ItemRef and (r as ItemRef).type == idx
	if held.call():
		return true
	await _until(_in_loop, ASK_TIMEOUT_MS, false)
	root.push_input(_key_of(&"cdda_wield"))
	var asked := func() -> bool: return _main.request_ui.is_showing() and _main.request_ui.widget is ListRequestWidget
	if not await _until(asked, ASK_TIMEOUT_MS, false):
		_check(false, "Q: CDDA asks what to wield (%s)" % [_live.request])
		return false
	var w := _main.request_ui.widget as ListRequestWidget
	var def: IdTables.Def = _cp.tables.def_at("itype", idx)
	var full := def.name.to_lower() if def != null and not def.name.is_empty() else name
	var pick := ""   # the entry named as the type first (not its magazines), else one holding `name`
	for starts: bool in [true, false]:
		for it: Dictionary in w.items:
			var n := str(it.get("plain", ""))
			var l := n.to_lower()
			var fits := l.begins_with(full) if starts else l.contains(name)
			if pick.is_empty() and it.get("enabled", false) and fits and not l.contains("magazine"):
				pick = n
	if pick.is_empty():
		_check(false, "Q: the wield list has a %s (%d entries)" % [name, w.items.size()])
		root.push_input(_esc_key())
		return false
	_answered = int(_live.request.get("id", 0))   # the list is answered by Enter below, not by _answer_prompt
	w.set_filter(pick)
	root.push_input(_enter_key())
	var ok := await _until(held, OP_TIMEOUT_MS, true)
	_check(ok, "Q: \"%s\" wielded" % pick)
	await _until(_in_loop, ASK_TIMEOUT_MS, true)
	return ok


func _in_loop() -> bool:
	return _main._in_main_loop() and not _main.request_ui.is_showing()


func _clear() -> void:
	_events.clear()


## The HP `uid` lost by the damage events since the last _clear() (each strike clears).
func _hp_lost(uid: int) -> int:
	var lost := 0
	for e: Dictionary in _events:
		if e.get("kind") == "damage" and int(e.get("uid", 0)) == uid:
			lost += int(e.get("amount", 0))
	return lost


func _on_events(events: Array) -> void:
	var blast := false
	for e: Variant in events:
		if e is Dictionary and _events.size() < MAX_EVENTS:
			_events.append(e)
			blast = blast or (e as Dictionary).get("kind") == "explosion"
	if blast:
		_note_blast.call_deferred()   # after every handler of this batch, main's ExplosionView included


func _note_blast() -> void:
	_blast_live = maxi(_blast_live, _main.explosions.live_count())
	_blast_shake = maxf(_blast_shake, _main.explosions.shake_strength())


## One turn passes: CDDA's main loop takes "pause" (it waits a turn); true once the snapshot's turn moved on.
func _pass_turn() -> bool:
	var t0 := _main.world.snapshot.turn
	if not _live.queue_action("pause"):
		return false
	var next := func() -> bool: return _main.world.snapshot.turn > t0 and _in_loop()
	return await _until(next, ASK_TIMEOUT_MS, false)


## Presses a range control and waits for the game's answer: "" done, else the error (or why it wasn't sent).
func _op(press: Callable, label: String) -> String:
	var before: Array = _cp._range_ops.keys()
	press.call()
	var sent: Array = _cp._range_ops.keys().filter(func(k: int) -> bool: return not k in before)
	if sent.is_empty():
		return "not sent: " + _cp.status.text
	return await _op_id(sent[0], label)


## Waits for range op `id`'s answer: "" done, else the error.
func _op_id(id: int, label: String) -> String:
	if id < 1:
		return "not sent"
	var answered := func() -> bool: return _done.has(id)
	if not await _until(answered, OP_TIMEOUT_MS, true):
		return "no answer"
	print("  %s -> %s" % [label, "done" if str(_done[id]).is_empty() else _done[id]])
	return _done[id]


## Waits (playing on) until `cond` holds; false on timeout or if the game stops. `answer`: prompts get the answer
## a player would give meanwhile (YES to confirmations, else cancel).
func _until(cond: Callable, timeout_ms: int, answer: bool) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		if _live.state == "ended" or _live.state == "failed":
			return false
		if answer:
			_answer_prompt()
		await create_timer(0.05).timeout
	return false


func _answer_prompt() -> void:
	var req := _live.request
	if req.is_empty() or req.get("timed", false) or req.get("context", "") == "RAW_KEY":
		return
	var id := int(req.get("id", 0))
	if id == _answered or req.get("kind", "") in ["shot", "swing"]:
		return
	_answered = id
	var a := {"id": id, "cancel": true}
	var acts: Array = req.get("actions", [])
	if req.get("kind", "") == "popup" and not acts.is_empty():
		a = {"id": id, "action": "YES" if "YES" in acts else acts[0]}
		if req.get("context", "") == "CANCEL_ACTIVITY_OR_IGNORE_QUERY":   # "Stop reloading?": go on
			a = {"id": id, "action": "IGNORE" if "IGNORE" in acts else "NO"}
	elif req.get("kind", "") == "menu" and (str(req.get("title", "")) + str(req.get("text", ""))).contains("wielding"):
		for en: Variant in req.get("entries", []):   # "Stop wielding X?": the first way offered
			if en is Dictionary and en.get("enabled", false):
				a = {"id": id, "entry": en.get("id")}
				print("    (%s)" % str(en.get("label", "")).left(60))
				break
	print("  answering %s %s %s: %s" % [req.get("kind", "?"), req.get("context", ""), acts, a])
	_live.answer(a)


func _key_of(action: StringName) -> InputEventKey:
	for e in InputActions.slots(action):
		if e is InputEventKey:
			var k := (e as InputEventKey).duplicate() as InputEventKey
			if k.keycode == KEY_NONE:
				k.keycode = k.physical_keycode
			if k.physical_keycode == KEY_NONE:
				k.physical_keycode = k.keycode
			k.pressed = true
			return k
	return null


func _esc_key() -> InputEventKey:
	return _plain_key(KEY_ESCAPE)


func _enter_key() -> InputEventKey:
	return _plain_key(KEY_ENTER)


func _plain_key(code: Key) -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = code
	k.physical_keycode = code
	k.pressed = true
	return k


func _stop() -> void:
	_live.stop()
	var stopped := func() -> bool: return _live.state != "running"
	await _until(stopped, 30000, false)
	_main.queue_free()
	await process_frame


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var b := _find_button(c, text)
		if b != null:
			return b
	return null


func _finish() -> void:
	if _failed == 0:
		TestDir.clean()
	else:
		print("  files kept in " + ProjectSettings.globalize_path(TestDir.dir()))
	print("combat live tests: " + ("all passed" if _failed == 0 else "%d FAILED" % _failed))
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)
