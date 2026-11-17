class_name VrCook
extends Node3D
## Block L9 (dynamic cooking), VR side: it shows, and starts what CDDA would. Over each pot (cookware:
## an item with CDDA's COOK or BOIL quality, Snapshot.cookware_at) lying on a heat square within RANGE_M of the
## head, a small card floats CARD_UP above the pot, turned to the head (yaw only, every frame: at most MAX_CARDS
## cards, the nearest):
## - the heat: "wood stove: lit (120 charges)", "fire: not lit" (the heat tool's name, else fire / furniture /
##   vehicle; fire level and charges when they say something);
## - what is in the pot: the first names from the id tables ("in it: water (250), chunk of meat +1 more"),
##   "N items" without tables, "empty";
## - a CDDA craft in progress among the contents: "making <result> 45%" and a bar;
## - else what the contents can become (CDDA's recipes, from `backend`): up to MAX_MATCHES lines,
##   "+ name — 12 min" when CDDA would start it now, "- name — needs <the first missing thing>" otherwise, "+N more";
##   "nothing to cook from this" (and "it only warms up" on a lit heat) when nothing matches.
## A lit pot with something in it steams (a few GPU particles; off when its card is gone).
## Recipes: `backend` is LiveSession, duck-typed (match_recipes(ItemRef) -> query id, 0 refused; the signal
## recipes_matched(container_uid, result), else recipe_matches(uid) polled), so the cards show heat and contents
## only until it has them. A pot is asked once per signature (contents + lit), only while it has something in it,
## no craft runs in it and it lies within CDDA's crafting reach (REACH) of the player; one query in flight per pot,
## MAX_QUERIES overall; LiveSession forgets unanswered queries after QUERY_TIMEOUT_S, so does this. An answer for a
## pot that wasn't asked, for an older query of it, or for contents that changed meanwhile is dropped (the pot is
## asked again). Answers are hostile all the same: clean_result bounds, cleans and clamps them.
## Pots are found through the submaps around the head only (≤ 4: RANGE_M is far less than a submap) and their
## `cookware` lists (≤ 16 each, Snapshot's cap), every TICK_S; a card's text and bar are redrawn only on a change.
## Cooking (`backend` with cook_item, LiveSession's L9 op; CDDA decides the rest, its questions stay its popups),
## only on a lit heat within REACH of the player:
## - the answer lists every match and CDDA would start exactly one of them now: it starts by itself, once per
##   contents and heat; what a craft sent from here leaves in the pot never starts another by itself (_hold);
## - else the trigger with an empty hand on a "+" line starts that one (press_at; the card says how);
## - a paused craft (taking the pot off the heat pauses it) goes on when the pot comes back onto a lit heat out of
##   the player's hands, or when its heat is lit under it (not when the player just walks up to it);
## - for STARTING_S after a send the card says "starting <name>...";
## - with `results` (VrRig's) the cook goes with a tag; CDDA refusing it puts its reason on the card for REFUSED_S
##   instead (the recipe lines stay under it; nothing starts by itself again for those contents and heat).
## Recipe ids come from the bridge's answers and the snapshot: only ones LiveSession.recipe_ok takes are used, and
## LiveSession checks every op again. A refused send (false) is tried again on the next look.
## The flat screen (E6) uses the same cards: `standalone` makes it update itself every frame and listen to its
## backend's events for CDDA's answers to its own cooks (VrResults); `head` is the screen's eye, `range_m` and
## `card_scale` suit a screen, and the crosshair picks a "+" line by ray (line_on_ray, press_ray; `pick_hint` says how).

const RANGE_M := 2.5        # cards for pots this near the head (range_m: VR's) ...
const MAX_RANGE_M := 6.0    # ... range_m at most
const RAY_M := 6.0          # line_on_ray: cards this far along the ray at most
const FLAT_RANGE_M := 4.0   # flat(): the screen's range_m, card_scale and pick_hint (the crosshair says the key)
const FLAT_SCALE := 2.5
const FLAT_HINT := "crosshair on a + line: cook it"
const MAX_CARDS := 4        # ... at most this many, the nearest
const MAX_MATCHES := 3      # recipe lines on a card
const MAX_SCAN := 32        # matches looked at in one answer (the contract's cap)
const MAX_MISSING := 8      # `missing` entries looked at (the contract's cap)
const MAX_QUERIES := 4      # match_recipes in flight at once (the bridge allows 8 for everyone)
const QUERY_TIMEOUT_S := 30.0   # LiveSession drops a query unanswered this long: ask again after it
const RETRY_S := 2.0        # a refused query (0) is tried again after this
const ERROR_RETRY_S := 5.0  # an answer with ok false ("out of reach") is asked again after this
const FORGET_S := 5.0       # answers for pots not near the head for this long are forgotten
const MAX_KEPT := 32        # answers kept at most (pots near the head come first)
const TICK_S := 0.2         # pots are looked for this often
const REACH := 6            # CDDA's crafting reach in squares: the bridge refuses farther ("out of reach")
const CARD_UP := 0.15       # metres over the pot's top
const FALLBACK_Y := 0.6     # a pot that isn't drawn: its top this high over its square's floor
const NAME_MAX := 32        # characters of a recipe, item or heat name
const MISSING_MAX := 36     # ... of a missing thing
const LINE_MAX := 48        # ... of any line
const ERROR_MAX := 24       # ... of a bridge error
const CONTENT_NAMES := 2    # contents named on the card; the rest are "+N more"
const MAX_TIME_S := 30 * 24 * 3600
const BAR_W := 0.2
const BAR_H := 0.014
const PIXEL := 0.0006       # Label3D metres per pixel (font 32: a line is about 2 cm high)
const STEAM_PUFFS := 6
const REFUSED_S := 6.0      # CDDA's reason for a refused cook stays on the card this long
const FONT := 32            # the card's font size (pixels)
const STARTING_S := 4.0     # "starting <name>..." shows this long after a cook was sent
const PICK_Z := 0.06        # press_at: the hand this near the card's plane ...
const PICK_PAD := 0.02      # ... and over a line's text, give or take this
const PICK_HINT := "empty hand on a + line, trigger: cook it"
const SOURCES := ["fire", "furniture", "vehicle"]   # Snapshot.HEAT_FIRE / HEAT_FURNITURE / HEAT_VEHICLE
## The bridge's refusals (contracts/bridge_api.md "Recipe queries") as the card says them.
const ERRORS := {"out of reach": "too far from you to check", "not found": "the pot isn't there any more",
		"not a container": "not a container"}


## One pot's card: a label, a bar for a craft in progress, steam. top_level: it stays in the world.
class Card extends Node3D:
	var uid := 0
	var text := ""          # what the label shows (redrawn only when it changes)
	var progress := -2.0    # 0..1 in the bar; < 0 no bar (-2: not drawn yet)
	var steaming := false
	var label: Label3D
	var back: MeshInstance3D
	var fill: MeshInstance3D
	var steam: GPUParticles3D
	var pot := {}           # the pots_near entry it was last drawn for
	var matches: Array = [] # what its lines 2.. list (clean_match each; press_at), [] none


var world: WorldView
var head: Node3D            # the XR camera (the flat screen's eye): cards are for pots near it and turn to it
var range_m := RANGE_M      # cards for pots this near the head (0.5..MAX_RANGE_M)
var card_scale := 1.0       # the cards' size (a screen wants them bigger; 0.5..4)
var pick_hint := PICK_HINT  # the line under a card's "+" lines: how to start one
## The flat screen: update every frame by itself and show CDDA's answers to its cooks (VR: VrRig does both).
var standalone := false:
	set(v):
		standalone = v
		set_process(v)
		if not v:
			_drop_events()
## L9: LiveSession (null in the mock): match_recipes / recipes_matched / recipe_matches, looked up by name.
var backend: Object = null:
	set(b):
		if b == backend:
			return
		_unhook()
		backend = b
		_pending.clear()
		_results.clear()
		_retry.clear()
		_sent.clear()
		_refused.clear()
		if b != null and is_instance_valid(b) and b.has_signal("recipes_matched"):
			b.connect("recipes_matched", _on_matched)
var cards := {}             # uid -> Card shown now (≤ MAX_CARDS)
var queries_sent := 0       # match_recipes calls that got a query id (tests)
var redraws := 0            # label texts set (tests: only on a change)
var cooks_sent := 0         # cook_item calls the backend took (tests)
## VrRig's: the tags cooks go with ({kind "cook", uid, name} comes back with the answer, on_result); null: no tags.
var results: VrResults = null
var _free: Array[Card] = [] # hidden cards for reuse
var _pending := {}          # uid -> {sig, id, at}: the query in flight for that pot
var _results := {}          # uid -> clean_result + {sig, until}
var _retry := {}            # uid -> clock before which a refused pot isn't asked again
var _sig := {}              # uid -> signature, the pots near the head at the last refresh
var _seen := {}             # uid -> clock it was last near the head
var _sent := {}             # uid -> {sig, name, at}: the cook sent for that pot's contents and heat
var _hold := {}             # uid -> contents_sig a craft sent from here left: not started again by itself
var _refused := {}          # uid -> {why, until}: CDDA said no to the cook sent for that pot
var _lit := {}              # uid -> its heat lit at the last look (pots near the head)
var _paused := {}           # uid -> type: pots seen with a craft in them on a heat
var _carried := {}          # uid -> true: a paused pot the player held (off the heat) at the last look
var _clock := 0.0
var _wait := 0.0
var _mats := {}
var _steam_mat: ParticleProcessMaterial
var _steam_mesh: QuadMesh
var _events_from: Object = null   # standalone: the backend whose events_arrived reaches on_events


func _init() -> void:
	name = "VrCook"
	set_process(false)


## The flat screen's cards (E6, made by main.gd in a live game without a headset): standalone, bigger, for pots
## within FLAT_RANGE_M of `eye`; GrabController.cook picks their "+" lines with the crosshair.
static func flat(w: WorldView, eye: Node3D, b: Object) -> VrCook:
	var c := VrCook.new()
	c.world = w
	c.head = eye
	c.backend = b
	c.range_m = FLAT_RANGE_M
	c.card_scale = FLAT_SCALE
	c.pick_hint = FLAT_HINT
	c.standalone = true
	return c


func _process(delta: float) -> void:
	if standalone:
		update(delta)


## Every frame (VrRig._process): pots are looked for every TICK_S, the cards turn to the head every frame.
func update(delta: float) -> void:
	if not is_finite(delta) or delta < 0.0:
		delta = 0.0
	_clock += delta
	_wait -= delta
	if standalone:
		_hook_events()
		results.tick(delta)
	if _wait <= 0.0:
		_wait = TICK_S
		refresh()
	face()


## Finds the pots near the head, asks for their recipes when due, and redraws the cards that changed.
func refresh() -> void:
	var snap: Snapshot = world.snapshot if world != null else null
	if snap == null or not is_instance_valid(head):
		_sig.clear()
		_lit.clear()
		_carried.clear()
		_show([])
		_expire()
		return
	var near := pots_near(snap, head_pos())
	_sig.clear()
	for p: Dictionary in near:
		_sig[p["uid"]] = signature(p["cw"], p["heat"])
		_seen[p["uid"]] = _clock
	_prune()
	_expire()
	_poll()
	for p: Dictionary in near:
		_maybe_ask(snap, p)
		_maybe_cook(snap, p)
	_note(snap, near)
	_show(near)


## The cookware on heat squares within RANGE_M of `hp`, nearest first, at most MAX_CARDS:
## [{uid, cw, square, heat, point (the pot's top), dist}]. Looks only at the submaps the range touches.
func pots_near(snap: Snapshot, hp: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not hp.is_finite():
		return out
	var hs := world.coords.world_to_ms(hp)
	var reach := clampf(range_m, 0.5, MAX_RANGE_M) if is_finite(range_m) else RANGE_M
	var r := ceili(reach / CddaCoords.TILE_M)
	var lo := CddaCoords.ms_to_sm(hs - Vector3i(r, r, 0))
	var hi := CddaCoords.ms_to_sm(hs + Vector3i(r, r, 0))
	for sy in range(lo.y, hi.y + 1):
		for sx in range(lo.x, hi.x + 1):
			var key := Vector3i(sx, sy, hs.z)
			var sm: Snapshot.Submap = snap.submaps.get(key)
			if sm == null:
				continue
			var base := CddaCoords.sm_to_ms(key)
			for k in mini(sm.cookware.size(), Snapshot.MAX_COOKWARE_PER_SUBMAP):
				var v: Variant = sm.cookware[k]
				if not v is Snapshot.Cookware:
					continue
				var cw: Snapshot.Cookware = v
				if cw.tile < 0 or cw.tile >= Snapshot.TILES or cw.uid <= 0:
					continue
				var sq := base + Vector3i(cw.tile % CddaCoords.SEEX, cw.tile / CddaCoords.SEEX, 0)
				var heat := snap.heat_at(sq)
				if heat.is_empty():
					continue   # only pots on the heat (Snapshot checks it too)
				var pt := pot_top(cw.uid, sq)
				var d := hp.distance_to(pt)
				if d <= reach:
					out.append({"uid": cw.uid, "cw": cw, "square": sq, "heat": heat, "point": pt, "dist": d})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["dist"] < b["dist"] or (a["dist"] == b["dist"] and a["uid"] < b["uid"]))
	if out.size() > MAX_CARDS:
		out.resize(MAX_CARDS)
	return out


## Where the pot's top is: over its drawn model (WorldView.item_slot), else FALLBACK_Y over its square.
func pot_top(uid: int, sq: Vector3i) -> Vector3:
	var s: Array = world.item_slot(uid)
	if s.size() >= 6 and s[3] is Vector3 and (s[3] as Vector3).is_finite():
		var size := clampf(float(s[5]), 0.0, 1.0) if (s[5] is float or s[5] is int) else 0.2
		return (s[3] as Vector3) + Vector3(0.0, size * 0.5, 0.0)
	return world.coords.ms_center_to_world(sq) + Vector3(0.0, FALLBACK_Y, 0.0)


func head_pos() -> Vector3:
	if not is_instance_valid(head):
		return Vector3.INF
	return head.global_position if head.is_inside_tree() else head.position


## Turns the cards to the head (yaw only: the text stays upright).
func face() -> void:
	if cards.is_empty():
		return
	var hp := head_pos()
	if not hp.is_finite():
		return
	for c: Card in cards.values():
		var d := hp - c.position
		d.y = 0.0
		if d.length_squared() > 1e-6:
			c.basis = Basis.looking_at(d, Vector3.UP, true).scaled(Vector3.ONE * _scale())   # its front (+Z) to the head


## What makes a pot worth asking again: its contents and whether its heat is lit.
static func signature(cw: Snapshot.Cookware, heat: Dictionary) -> int:
	return hash([cw.type, cw.contents, _yes(heat.get("lit"))])


## What a pot holds, whatever its heat: a craft sent from here holds what it left by this.
static func contents_sig(cw: Snapshot.Cookware) -> int:
	return hash([cw.type, cw.contents])


## The player can reach square `sq` for crafting (CDDA's crafting reach, same level; walls are the bridge's to judge).
static func in_reach(player: Vector3i, sq: Vector3i) -> bool:
	return sq.z == player.z and maxi(absi(sq.x - player.x), absi(sq.y - player.y)) <= REACH


## The backend can be asked (LiveSession with the recipe wrapper).
func can_ask() -> bool:
	return is_instance_valid(backend) and backend.has_method("match_recipes")


## The backend can cook (LiveSession with the L9 ops).
func can_cook() -> bool:
	return is_instance_valid(backend) and backend.has_method("cook_item")


## What the card says is starting in pot `uid` ("" nothing): for STARTING_S after a cook for these contents and heat.
func starting(uid: int) -> String:
	var s: Dictionary = _sent.get(uid, {})
	if s.is_empty() or s["sig"] != _sig.get(uid) or _clock >= float(s["at"]) + STARTING_S or not refusal(uid).is_empty():
		return ""
	return s["name"]


## CDDA's reason for refusing the cook sent for pot `uid`, for REFUSED_S after it came; "" none.
func refusal(uid: int) -> String:
	var r: Dictionary = _refused.get(uid, {})
	if r.is_empty():
		return ""
	if _clock >= float(r["until"]):
		_refused.erase(uid)
		return ""
	return r["why"]


## CDDA's answer to the cook sent for pot `uid` (VrRig, from VrResults): refused, `why` shows on its card.
func on_result(uid: int, done: bool, why: String) -> void:
	if done or not _sent.has(uid):
		_refused.erase(uid)
		return
	_refused[uid] = {"why": VrResults.clean(why), "until": _clock + REFUSED_S}
	while _refused.size() > MAX_KEPT:
		_refused.erase(_refused.keys()[0])


## The card line under the hand at `pt` (world): {uid, line (0 = the top one), match (the clean_match it lists,
## {} none)}; {} off every card. A line is its text's width (PICK_PAD more) and its height; the hand within PICK_Z
## of the card's plane.
func line_at(pt: Vector3) -> Dictionary:
	if not pt.is_finite():
		return {}
	for c: Card in cards.values():
		var hit := _line_on(c, pt)
		if not hit.is_empty():
			return hit
	return {}


## The card line the ray from `origin` along `dir` meets first within RAY_M (the flat screen's crosshair): line_at's
## {uid, line, match} and the `point`; {} for none.
func line_on_ray(origin: Vector3, dir: Vector3) -> Dictionary:
	if not origin.is_finite() or not dir.is_finite() or dir.length_squared() < 1e-8:
		return {}
	var d := dir.normalized()
	var best := {}
	var best_t := RAY_M
	for c: Card in cards.values():
		if not c.visible or c.text.is_empty():
			continue
		var xf := c.global_transform if c.is_inside_tree() else c.transform
		var n := xf.basis.z.normalized()
		var den := n.dot(d)
		if absf(den) < 1e-4:
			continue
		var t := n.dot(xf.origin - origin) / den
		if t < 0.0 or t > best_t:
			continue
		var hit := _line_on(c, origin + d * t)
		if not hit.is_empty():
			hit["point"] = origin + d * t
			best = hit
			best_t = t
	return best


## The trigger with an empty hand at `pt`: on a "+" line (a recipe CDDA would start now) that recipe starts. True
## when a cook was sent.
func press_at(pt: Vector3) -> bool:
	return _press(line_at(pt))


## The flat screen's press (E with the crosshair on a "+" line): that recipe starts. True when a cook was sent.
func press_ray(origin: Vector3, dir: Vector3) -> bool:
	return _press(line_on_ray(origin, dir))


## The line of card c at world point `pt` (in its plane, within PICK_Z), as line_at's; {} off it.
func _line_on(c: Card, pt: Vector3) -> Dictionary:
	if not c.visible or c.text.is_empty():
		return {}
	var font: Font = c.label.font if c.label.font != null else ThemeDB.fallback_font
	var lh := font.get_height(FONT) * PIXEL
	var xf := c.global_transform if c.is_inside_tree() else c.transform
	var l := xf.affine_inverse() * pt
	var up := l.y - c.label.position.y
	if lh <= 0.0 or up < 0.0 or absf(l.z) > PICK_Z:
		return {}
	var lines := c.text.split("\n")
	var k := lines.size() - 1 - int(up / lh)   # bottom-aligned: the last line sits on the label's origin
	if k < 0:
		return {}
	var w := font.get_string_size(lines[k], HORIZONTAL_ALIGNMENT_LEFT, -1, FONT).x * PIXEL
	if absf(l.x) > w * 0.5 + PICK_PAD:
		return {}
	var i := k - 2
	return {"uid": c.uid, "line": k, "match": c.matches[i] if i >= 0 and i < c.matches.size() else {}}


## Whether `hit` (line_at's or line_on_ray's) is a "+" line a press would start now (a recipe CDDA can start, the
## pot within reach, a backend that cooks); nothing is sent.
func can_press(hit: Dictionary) -> bool:
	if not can_cook() or world == null or world.snapshot == null:
		return false
	var mv: Variant = hit.get("match")
	var cv: Variant = cards.get(hit.get("uid", 0))
	if not mv is Dictionary or not cv is Card:
		return false
	var m: Dictionary = mv
	var c: Card = cv
	return not m.is_empty() and not c.pot.is_empty() and m.get("can_start") is bool and m["can_start"] \
			and not str(m.get("recipe", "")).is_empty() and in_reach(world.snapshot.player_pos, c.pot["square"])


## Starts the "+" line `hit` (line_at's) lists. True when a cook was sent.
func _press(hit: Dictionary) -> bool:
	if not can_press(hit):
		return false
	var c: Card = cards[hit["uid"]]
	var m: Dictionary = hit["match"]
	return _cook(c.pot, m["recipe"], m["name"])


func pending_count() -> int:
	return _pending.size()


# --- answers ---

## An answer for pot `uid` (the signal, or a polled recipe_matches): kept only when it answers the query in flight
## for that pot (same id when it carries one, same container) and the pot's contents and heat haven't changed since
## it was asked. Returns whether it was kept.
func accept(uid_v: Variant, result: Variant) -> bool:
	if not uid_v is int:
		return false
	var uid: int = uid_v
	var p: Dictionary = _pending.get(uid, {})
	if p.is_empty():
		return false   # not asked (another pot, or one answered or given up on)
	if not result is Dictionary:
		push_warning("VrCook: a recipe answer that isn't a dictionary, dropped")
		_pending.erase(uid)
		_retry[uid] = _clock + RETRY_S
		return false
	var d: Dictionary = result
	if not _same_int(d.get("id"), p["id"]) or not _same_int(d.get("container"), uid):
		return false   # an older query's answer (or someone else's): keep waiting for ours
	_pending.erase(uid)
	if not _sig.has(uid) or _sig[uid] != p["sig"]:
		return false   # the contents or the heat changed meanwhile (or the pot left): asked again on the next look
	var c := clean_result(d)
	c["sig"] = p["sig"]
	c["until"] = INF if c["ok"] else _clock + ERROR_RETRY_S
	_results[uid] = c
	return true


## A recipe answer made safe: {ok, error (≤ ERROR_MAX), matches (≤ MAX_MATCHES clean_match), more (valid ones
## not shown, of the first MAX_SCAN)}.
static func clean_result(v: Variant) -> Dictionary:
	var out := {"ok": false, "error": "", "matches": [] as Array[Dictionary], "more": 0}
	if not v is Dictionary:
		return out
	var d: Dictionary = v
	if not d.get("ok") is bool or not d.get("ok"):
		out["error"] = _text(d.get("error"), ERROR_MAX)
		return out
	out["ok"] = true
	var ms: Variant = d.get("matches")
	if not ms is Array:
		return out
	var list: Array = ms
	var kept: Array[Dictionary] = []
	var valid := 0
	for i in mini(list.size(), MAX_SCAN):
		var m := clean_match(list[i])
		if m.is_empty():
			continue
		valid += 1
		if kept.size() < MAX_MATCHES:
			kept.append(m)
	out["matches"] = kept
	out["more"] = valid - kept.size()
	return out


## One match made safe: {name, time_s (-1 unknown), can_start, missing (the first missing thing, "" none), recipe
## (its id when LiveSession.recipe_ok takes it, else "": shown, never sent)}; {} when it has no usable name.
static func clean_match(v: Variant) -> Dictionary:
	if not v is Dictionary:
		return {}
	var m: Dictionary = v
	var nm := _text(m.get("name"), NAME_MAX)
	if nm.is_empty():
		nm = _text(m.get("recipe"), NAME_MAX).replace("_", " ").strip_edges()
	if nm.is_empty():
		return {}
	var secs := -1
	var t: Variant = m.get("time_s")
	if t is int:
		secs = clampi(t, 0, MAX_TIME_S)
	elif t is float and is_finite(t):
		secs = int(clampf(t, 0.0, MAX_TIME_S))
	var miss := ""
	var mv: Variant = m.get("missing")
	if mv is Array or mv is PackedStringArray:
		for i in mini(mv.size(), MAX_MISSING):
			miss = _text(mv[i], MISSING_MAX)
			if not miss.is_empty():
				break
	var rid: Variant = m.get("recipe")
	var recipe: String = rid if rid is String and LiveSession.recipe_ok(rid) else ""
	return {"name": nm, "time_s": secs, "can_start": _yes(m.get("can_start")), "missing": miss, "recipe": recipe}


# --- card text ---

## "wood stove: lit (fire 2/3, 120 charges)": the heat tool's name (else the source), lit or not, and the fire
## level / charges when they say something.
static func heat_text(heat: Dictionary, tables: IdTables) -> String:
	if heat.is_empty():
		return "no heat"
	var src := _int(heat.get("source"), -1, 99)
	var tool := _int(heat.get("tool"), 0, 1 << 30)
	var nm := _item_name(tool, tables) if tool > 0 else ""
	if nm.is_empty():
		nm = SOURCES[src] if src >= 0 and src < SOURCES.size() else "heat"
	var lit := _yes(heat.get("lit"))
	var extra: Array[String] = []
	var fire := _int(heat.get("fire"), 0, 3)
	if fire > 0:
		extra.append("fire %d/3" % fire)
	var ch := _int(heat.get("charges"), 0, Snapshot.MAX_CHARGES)
	if src != Snapshot.HEAT_FIRE and tool > 0 and ch > 0:
		extra.append("%d charge%s" % [ch, "" if ch == 1 else "s"])
	var s := "%s: %s" % [nm, "lit" if lit else "not lit"]
	if not extra.is_empty():
		s += " (%s)" % ", ".join(extra)
	return _cap(s)


## "in it: clean water (250), chunk of meat +1 more"; "N items" without names; "empty".
static func contents_text(contents: PackedInt64Array, tables: IdTables) -> String:
	var n := contents.size() / Snapshot.COOK_ITEM_STRIDE
	if n <= 0:
		return "empty"
	if tables == null:
		return "%d item%s" % [n, "" if n == 1 else "s"]
	var parts: Array[String] = []
	for i in mini(n, CONTENT_NAMES):
		var nm := _item_name(contents[i * Snapshot.COOK_ITEM_STRIDE + 1], tables)
		if nm.is_empty():
			nm = "something"
		var count := clampi(contents[i * Snapshot.COOK_ITEM_STRIDE + 2], 0, Snapshot.MAX_CHARGES)
		parts.append(nm + (" (%d)" % count if count > 1 else ""))
	var s := "in it: " + ", ".join(parts)
	if n > CONTENT_NAMES:
		s += " +%d more" % (n - CONTENT_NAMES)
	return _cap(s)


## "making vegetable soup 45%" (the result's name, else the recipe id, else "something").
static func craft_text(cw: Snapshot.Cookware, tables: IdTables) -> String:
	return _cap("making %s %d%%" % [craft_name(cw, tables), clampi(cw.craft_progress, 0, 1000) / 10])


## The craft's name: its result's, else its recipe id, else "something".
static func craft_name(cw: Snapshot.Cookware, tables: IdTables) -> String:
	var nm := _item_name(cw.craft_result, tables) if cw.craft_result > 0 else ""
	if nm.is_empty():
		nm = _text(cw.craft_recipe, NAME_MAX).replace("_", " ").strip_edges()
	return nm if not nm.is_empty() else "something"


## "+ name — 12 min" (CDDA would start it now), "- name — needs fire" (else, with the first missing thing).
static func match_line(m: Dictionary) -> String:
	var nm := _text(m.get("name"), NAME_MAX)
	var secs: int = m.get("time_s", -1) if m.get("time_s", -1) is int else -1
	if _yes(m.get("can_start")):
		return _cap("+ %s — %s" % [nm, time_text(secs)] if secs >= 0 else "+ " + nm)
	var miss := _text(m.get("missing"), MISSING_MAX)
	return _cap("- %s — needs %s" % [nm, miss] if not miss.is_empty() else "- %s (can't start)" % nm)


## Game seconds as "30 s", "12 min", "1 h 5 min".
static func time_text(secs: int) -> String:
	secs = clampi(secs, 0, MAX_TIME_S)
	if secs < 60:
		return "%d s" % secs
	var mins := ceili(secs / 60.0)
	if mins < 60:
		return "%d min" % mins
	return "%d h" % (mins / 60) if mins % 60 == 0 else "%d h %d min" % [mins / 60, mins % 60]


## The card's lines for one pot near the head (pots_near's entry).
func card_text(p: Dictionary, snap: Snapshot) -> String:
	var cw: Snapshot.Cookware = p["cw"]
	var tables: IdTables = world.tables if world != null else null
	var lines: Array[String] = [heat_text(p["heat"], tables), contents_text(cw.contents, tables)]
	if cw.craft_progress > 0:
		lines.append(craft_text(cw, tables))
	elif not cw.contents.is_empty() and can_ask():
		var st := starting(p["uid"])
		var no := refusal(p["uid"])
		if not st.is_empty():
			lines.append(_cap("starting %s..." % st))
		else:
			if not no.is_empty():
				lines.append(_cap(no))
			lines.append_array(_recipe_lines(p, snap))
	return "\n".join(lines)


func _recipe_lines(p: Dictionary, snap: Snapshot) -> Array[String]:
	var uid: int = p["uid"]
	var out: Array[String] = []
	var r: Dictionary = _results.get(uid, {})
	if not r.is_empty() and _sig.has(uid) and r["sig"] == _sig[uid]:
		if not r["ok"]:
			out.append(ERRORS.get(r["error"], "can't check recipes"))
			return out
		var ms: Array = r["matches"]
		if ms.is_empty():
			out.append("nothing to cook from this")
			if _yes(p["heat"].get("lit")):
				out.append("it only warms up")
			return out
		for m: Dictionary in ms:
			out.append(match_line(m))
		if r["more"] > 0:
			out.append("+%d more" % r["more"])
		if can_cook() and ms.any(func(m: Dictionary) -> bool: return m["can_start"] and not m["recipe"].is_empty()):
			out.append(pick_hint.left(LINE_MAX))
		return out
	out.append("checking recipes..." if in_reach(snap.player_pos, p["square"]) else "(out of your reach)")
	return out


# --- inside ---

func _maybe_ask(snap: Snapshot, p: Dictionary) -> void:
	if not can_ask():
		return
	var cw: Snapshot.Cookware = p["cw"]
	var uid: int = p["uid"]
	if cw.craft_progress > 0 or cw.contents.is_empty() or cw.type < 1 or _pending.has(uid):
		return
	var r: Dictionary = _results.get(uid, {})
	if not r.is_empty() and r["sig"] == _sig[uid] and _clock < float(r["until"]):
		return   # answered for these contents and this heat
	if _pending.size() >= MAX_QUERIES or _clock < float(_retry.get(uid, -INF)):
		return
	if not in_reach(snap.player_pos, p["square"]):
		return   # the bridge would refuse it
	var id_v: Variant = backend.call("match_recipes", ItemRef.on_square(uid, cw.type, p["square"]))
	var id: int = id_v if id_v is int else 0
	if id < 1:
		_retry[uid] = _clock + RETRY_S
		return
	queries_sent += 1
	_pending[uid] = {"sig": _sig[uid], "id": id, "at": _clock}


## L9: starts or goes on with a craft in pot `p` when due (see the top).
func _maybe_cook(snap: Snapshot, p: Dictionary) -> void:
	var uid: int = p["uid"]
	var cw: Snapshot.Cookware = p["cw"]
	var sent: Dictionary = _sent.get(uid, {})
	if not sent.is_empty() and sent["sig"] != _sig[uid] and cw.craft_progress <= 0:
		_sent.erase(uid)
		_hold[uid] = contents_sig(cw)   # what the craft left: it doesn't start another by itself
	if not can_cook() or cw.type < 1 or not _yes(p["heat"].get("lit")) or not in_reach(snap.player_pos, p["square"]):
		return
	if cw.craft_progress > 0:
		if ((_lit.has(uid) and not _lit[uid]) or _carried.has(uid)) and LiveSession.recipe_ok(cw.craft_recipe):
			_cook(p, cw.craft_recipe, craft_name(cw, world.tables))   # back on the heat, or its heat lit: go on
		return
	if _sent.has(uid) or (_hold.has(uid) and _hold[uid] == contents_sig(cw)):
		return
	var r: Dictionary = _results.get(uid, {})
	if r.is_empty() or r["sig"] != _sig[uid] or not r["ok"] or r["more"] > 0:
		return
	var one := {}
	for m: Dictionary in r["matches"]:
		if m["can_start"]:
			if not one.is_empty():
				return   # several: the player picks one (press_at)
			one = m
	if not one.is_empty() and not one["recipe"].is_empty():
		_cook(p, one["recipe"], one["name"])


## Sends cook `recipe` for pot `p` (pots_near's entry); remembered for its contents and heat when the backend took it.
func _cook(p: Dictionary, recipe: String, nm: String) -> bool:
	var uid: int = p["uid"]
	var cw: Snapshot.Cookware = p["cw"]
	var tag := results.open({"kind": "cook", "uid": uid, "name": nm}) if results != null else 0
	var v: Variant = backend.call("cook_item", float(uid), float(cw.type), p["square"], recipe, 1, tag)
	if not (v is bool and v):
		if results != null:
			results.close(tag)
		return false
	_refused.erase(uid)
	cooks_sent += 1
	_sent[uid] = {"sig": _sig.get(uid, 0), "name": nm, "at": _clock}
	return true


## For the next look: whose heat was lit, which pots hold a craft, and which of those the player holds now.
func _note(snap: Snapshot, near: Array[Dictionary]) -> void:
	_lit.clear()
	_carried.clear()
	for p: Dictionary in near:
		var cw: Snapshot.Cookware = p["cw"]
		_lit[p["uid"]] = _yes(p["heat"].get("lit"))
		if cw.craft_progress > 0:
			_paused[p["uid"]] = cw.type
		else:
			_paused.erase(p["uid"])
	for uid: int in _paused.keys():
		if not _lit.has(uid) and ItemActions.carried_row(snap, uid, _paused[uid]) >= 0:
			_carried[uid] = true
			_seen[uid] = _clock   # kept while held: putting it back goes on with the craft


## Without the signal, LiveSession's last result per pot (recipe_matches) is read for the pots asked.
func _poll() -> void:
	if _pending.is_empty() or not is_instance_valid(backend) or backend.has_signal("recipes_matched") \
			or not backend.has_method("recipe_matches"):
		return
	for uid: int in _pending.keys():
		var r: Variant = backend.call("recipe_matches", uid)
		if r is Dictionary and not (r as Dictionary).is_empty():
			accept(uid, r)


func _on_matched(uid: Variant, result: Variant) -> void:
	accept(uid, result)


## Queries unanswered for QUERY_TIMEOUT_S are given up (LiveSession dropped them too).
func _expire() -> void:
	for uid: int in _pending.keys():
		if _clock - float(_pending[uid]["at"]) > QUERY_TIMEOUT_S:
			_pending.erase(uid)


## Forgets answers, refusals and sightings of pots not near the head for FORGET_S, and keeps MAX_KEPT at most.
func _prune() -> void:
	for uid: int in _seen.keys():
		if _clock - float(_seen[uid]) > FORGET_S or (_seen.size() > MAX_KEPT and not _sig.has(uid)):
			_seen.erase(uid)
	for d: Dictionary in [_results, _retry, _sent, _hold, _paused, _refused]:
		for uid: int in d.keys():
			if not _seen.has(uid):
				d.erase(uid)


func _show(near: Array[Dictionary]) -> void:
	var keep := {}
	for p: Dictionary in near:
		keep[p["uid"]] = true
	for uid: int in cards.keys():
		if not keep.has(uid):
			var gone: Card = cards[uid]
			gone.visible = false
			gone.steam.emitting = false
			gone.steaming = false
			gone.pot = {}
			gone.matches = []
			cards.erase(uid)
			_free.append(gone)
	if near.is_empty():
		return
	var snap: Snapshot = world.snapshot
	for p: Dictionary in near:
		var uid: int = p["uid"]
		var c: Card = cards.get(uid)
		if c == null:
			c = _take_card()
			c.uid = uid
			c.text = ""
			c.progress = -2.0
			cards[uid] = c
		c.position = (p["point"] as Vector3) + Vector3(0.0, CARD_UP * _scale(), 0.0)
		c.visible = true
		c.pot = p
		c.matches = _listed(p)
		var t := card_text(p, snap)
		if t != c.text:
			c.text = t
			c.label.text = t
			redraws += 1
		var cw: Snapshot.Cookware = p["cw"]
		var prog := clampi(cw.craft_progress, 0, 1000) / 1000.0 if cw.craft_progress > 0 else -1.0
		if prog != c.progress:
			_set_bar(c, prog)
		var st := _yes(p["heat"].get("lit")) and not cw.contents.is_empty()
		if st != c.steaming:
			c.steaming = st
			c.steam.emitting = st


## The matches card lines 2.. list for pot `p` now; [] when they list none (a craft, starting, no answer yet).
func _listed(p: Dictionary) -> Array:
	var cw: Snapshot.Cookware = p["cw"]
	var uid: int = p["uid"]
	if cw.craft_progress > 0 or cw.contents.is_empty() or not can_ask() or not starting(uid).is_empty():
		return []
	var r: Dictionary = _results.get(uid, {})
	if r.is_empty() or not _sig.has(uid) or r["sig"] != _sig[uid] or not r["ok"]:
		return []
	return r["matches"]


func _take_card() -> Card:
	if not _free.is_empty():
		return _free.pop_back()
	var c := Card.new()
	c.name = "CookCard"
	c.top_level = true   # stays where the pot is while the rig walks or teleports
	var l := Label3D.new()
	l.pixel_size = PIXEL
	l.font_size = FONT
	l.outline_size = 8
	l.modulate = Color(0.97, 0.94, 0.86)
	l.outline_modulate = Color(0.08, 0.06, 0.04, 0.9)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM   # the text grows up from over the bar
	l.position = Vector3(0.0, BAR_H + 0.008, 0.0)
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	c.label = l
	c.add_child(l)
	c.back = _quad(Vector2(BAR_W, BAR_H), _mat("back", Color(0.1, 0.09, 0.08, 0.75)))
	c.add_child(c.back)
	c.fill = _quad(Vector2(BAR_W, BAR_H * 0.7), _mat("fill", Color(1.0, 0.62, 0.2)))
	c.add_child(c.fill)
	c.steam = _make_steam()
	c.steam.position = Vector3(0.0, -CARD_UP, 0.0)   # at the pot's top
	c.add_child(c.steam)
	add_child(c)
	return c


func _scale() -> float:
	return clampf(card_scale, 0.5, 4.0) if is_finite(card_scale) else 1.0


## Standalone: on_events listens to the backend's events_arrived, the current backend's only; a new one starts
## with fresh tags.
func _hook_events() -> void:
	var b: Object = backend if is_instance_valid(backend) else null
	if b == _events_from and results != null:
		return
	_drop_events()
	results = VrResults.new()
	_events_from = b
	if b != null and b.has_signal("events_arrived"):
		b.connect("events_arrived", on_events)


func _drop_events() -> void:
	if is_instance_valid(_events_from) and _events_from.has_signal("events_arrived") \
			and _events_from.is_connected("events_arrived", on_events):
		_events_from.disconnect("events_arrived", on_events)
	_events_from = null


## Standalone: the bridge's events; CDDA's answers to this card's cooks (VrResults) go to on_result.
func on_events(events: Variant) -> void:
	if results == null:
		return
	for r: Dictionary in results.on_events(events):
		var info: Dictionary = r["info"]
		var kind: Variant = info.get("kind")
		if kind is String and kind == "cook":
			on_result(int(info.get("uid", 0)), r["done"], r["why"])


## prog 0..1: the bar at that fill; < 0: no bar.
func _set_bar(c: Card, prog: float) -> void:
	c.progress = prog
	c.back.visible = prog >= 0.0
	c.fill.visible = prog > 0.005
	if c.fill.visible:
		var f := clampf(prog, 0.005, 1.0)
		c.fill.scale = Vector3(f, 1.0, 1.0)
		c.fill.position = Vector3(-BAR_W * 0.5 * (1.0 - f), 0.0, 0.001)


func _quad(size: Vector2, mat: StandardMaterial3D) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	return mi


func _mat(key: String, col: Color) -> StandardMaterial3D:
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		if col.a < 1.0:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mats[key] = m
	return _mats[key]


## A few soft puffs rising from the pot (STEAM_PUFFS, GPU-side; materials shared by every card).
func _make_steam() -> GPUParticles3D:
	if _steam_mat == null:
		_steam_mat = ParticleProcessMaterial.new()
		_steam_mat.direction = Vector3.UP
		_steam_mat.spread = 12.0
		_steam_mat.initial_velocity_min = 0.05
		_steam_mat.initial_velocity_max = 0.1
		_steam_mat.gravity = Vector3(0.0, 0.03, 0.0)
		_steam_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		_steam_mat.emission_sphere_radius = 0.04
		_steam_mat.scale_min = 0.6
		_steam_mat.scale_max = 1.3
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 0))
		g.set_color(1, Color(1, 1, 1, 0))
		g.add_point(0.3, Color(1, 1, 1, 0.3))
		var gt := GradientTexture1D.new()
		gt.gradient = g
		_steam_mat.color_ramp = gt
		_steam_mesh = QuadMesh.new()
		_steam_mesh.size = Vector2(0.07, 0.07)
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.92, 0.94, 0.97)
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		_steam_mesh.material = m
	var p := GPUParticles3D.new()
	p.name = "Steam"
	p.amount = STEAM_PUFFS
	p.lifetime = 1.6
	p.emitting = false
	p.process_material = _steam_mat
	p.draw_pass_1 = _steam_mesh
	p.visibility_aabb = AABB(Vector3(-0.3, -0.1, -0.3), Vector3(0.6, 1.0, 0.6))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


func _unhook() -> void:
	if is_instance_valid(backend) and backend.has_signal("recipes_matched") \
			and backend.is_connected("recipes_matched", _on_matched):
		backend.disconnect("recipes_matched", _on_matched)


## `v` is the integer `want` (an int, or a whole float as raw JSON gives); a missing value (null) counts as it.
static func _same_int(v: Variant, want: int) -> bool:
	if typeof(v) == TYPE_NIL:
		return true   # the answer doesn't say: take it as ours
	if v is int:
		return v == want
	return v is float and is_finite(v) and absf(v) < 9.0e15 and int(v) == want and float(int(v)) == v


static func _yes(v: Variant) -> bool:
	return v is bool and v


static func _int(v: Variant, lo: int, hi: int) -> int:
	if v is int:
		return clampi(v, lo, hi)
	if v is float and is_finite(v):
		return int(clampf(v, lo, hi))
	return lo


static func _item_name(type: int, tables: IdTables) -> String:
	if tables == null or type <= 0:
		return ""
	var d := tables.def_at("itype", type)
	if d == null:
		return ""
	return _text(d.name if not d.name.is_empty() else d.id, NAME_MAX)


static func _text(v: Variant, cap: int) -> String:
	if v is String or v is StringName:
		return InventoryModel.clean(str(v), cap)
	return ""


static func _cap(s: String) -> String:
	return s if s.length() <= LINE_MAX else s.left(LINE_MAX - 3) + "..."
