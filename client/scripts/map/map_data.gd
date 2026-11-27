class_name MapData
extends RefCounted
## G5 map (lead-ui, 2026-11-26; docs/MAP.md): the one data layer behind the screen map (MapCanvas in MapView) and
## VR's held map (lead-vr's vr_map.gd, the same canvas). It reads the overmap a page at a time
## (LiveSession.query_overmap: 32x32 cells on one level, only what CDDA's own map screen would show at the vision
## level the player has), keeps the pages while a view is open and drops them all when the last one closes. CDDA
## decides what was seen; this only asks, checks what comes back and keeps it.

signal changed
## Slice 2: a note write (set_note / delete_note, its tag) was answered: done, or refused with CDDA's sentence.
signal note_done(tag: int, ok: bool, text: String)

const PAGE := 32
const CELLS := PAGE * PAGE
const MAX_PAGES := 256        # kept while open (the least recently wanted go first)
const MAX_WANTED := 160       # pages a view may ask for at once, nearest its middle first (4K at the smallest zoom)
const WANT_SPAN := 8   # pages each side of a view's middle looked at, at most (17 x 17 before the cut)
const MAX_LOOKS := 256
const MAX_NOTES := 256
const MAX_PATH := 2048
const MAX_NAME := 60          # a look's name, characters (the bridge's cap)
const MAX_SYMBOL := 4         # a look's or note's symbol, characters (one glyph)
const MAX_NOTE := 450         # CDDA's note box: columns (characters here)
const MAX_RADIUS := 180       # a danger note's radius drawn, cells (the bridge sends at most 180)
const UNSENT := Color(0.5, 0.5, 0.5)   # a seen cell whose look was left out of a full page
const MAX_XY := 1 << 24       # |x|, |y| of a cell (absolute OMT; the bridge's bound)
const Z_MIN := -10
const Z_MAX := 10
const MAX_RESULT_BYTES := 65536
const MAX_QUERY_ID := (1 << 53) - 1
const MAX_VISION := 4
## CDDA's om_vision_level, by the int the bridge sends.
const VISION_WORDS := ["not seen", "seen vaguely", "seen in outline", "seen in detail", "fully seen"]
const FLAG_EXPLORED := 1
const FLAG_VEHICLE := 2
const FLAG_CAMP := 4
const FLAG_MISSION := 8
const SQUARES_PER_CELL := 24   # map squares on an OMT's side (2 submaps)
const RETRY_MS := 5000         # a page that failed is asked again after this
const NO_BRIDGE := "The map isn't connected to the game yet."
const ERRORS := ["internal", "too large"]
## Slice 2, notes. The symbols the note dialog and VR's wheel offer: CDDA reads back any printable ASCII character but
## ':' and ';' (its prefix marks) as a note's glyph; these are the usual ones.
const NOTE_SYMBOLS := "N!X*+$#?@&%=^~"
## CDDA's note colours (color_by_string_map, and its default Y first): [code sent, label, colour].
const NOTE_COLORS := [
	["Y", "yellow", Color("#ffff00")], ["R", "red", Color("#ff0000")], ["r", "light red", Color("#ff9696")],
	["G", "green", Color("#006e00")], ["g", "light green", Color("#00ff00")], ["B", "blue", Color("#0000c8")],
	["b", "light blue", Color("#6464ff")], ["C", "cyan", Color("#0096b4")], ["c", "light cyan", Color("#00f0ff")],
	["P", "pink", Color("#fe00fe")], ["m", "magenta", Color("#8b3a62")], ["W", "white", Color("#ffffff")],
	["lg", "light gray", Color("#969696")], ["dg", "dark gray", Color("#636363")], ["br", "brown", Color("#5c3317")],
]
const MAX_DANGER_RADIUS := 20   # CDDA's own range for a danger mark ("Danger radius in overmap squares? (0-20)")
const MAX_TAG := 2147483647
const MAX_EVENTS := 256         # events looked at in one batch
const WRITE_TIMEOUT_MS := 10000
const NO_ANSWER := "The game didn't answer."
const REFUSED := "The game refused it."


## One page as read: cells row by row (index ly * PAGE + lx).
class Page:
	var origin: Vector3i
	var look := PackedInt32Array()     # 1-based into looks, 0 none
	var vision := PackedByteArray()
	var flags := PackedInt32Array()
	var looks: Array[Dictionary] = []  # {name, symbol, color: Color}
	var notes := {}                    # Vector2i (local) -> {text, symbol, color: Color, danger, radius}
	var truncated := false


var live: LiveSession
## The player's cell (absolute OMT; z the level), from the last snapshot.
var player_cell := Vector3i.ZERO
var has_player := false
## The current destination's path (absolute OMT, the player's end first as CDDA keeps it) and its end, from the
## player's page read; empty / null when there is none.
var path: Array[Vector3i] = []
var destination: Variant = null
## Why the map shows nothing ("" when it reads).
var note := ""

var _users := 0
var _pages := {}                      # Vector3i origin -> Page
var _used := {}                       # Vector3i origin -> a counter (higher: wanted later)
var _tick := 0
var _wanted: Array[Vector3i] = []     # what the views show now, nearest their middle first
var _wanted_by := {}                  # view id -> its pages (the screen map and VR's may both be open)
var _asked := Vector3i.MAX            # the page out (MAX none)
var _asked_path := false
var _stale := {}                      # origin -> _seq when marked to read again (the player's page after a step)
var _seq := 0
var _asked_seq := 0                   # _seq when the page out was asked
var _failed := {}                     # origin -> msec it failed
var _write_tag := 0                   # the note write out (0 none)
var _write_cell := Vector3i.ZERO
var _write_at := 0                    # msec it went out


## A view opened: pages are read from now (reference-counted: the screen map and VR's map may both be open).
func open() -> void:
	_users += 1
	if _users == 1:
		_mark(page_origin(player_cell))
		_ask_next()
		changed.emit()


## A view closed; when the last one does, every page is dropped (the next opening reads them again).
func close() -> void:
	if _users == 0:
		return
	_users -= 1
	if _users == 0:
		_pages.clear()
		_used.clear()
		_wanted.clear()
		_wanted_by.clear()
		_stale.clear()
		_failed.clear()
		path.clear()
		destination = null
		changed.emit()


func is_open() -> bool:
	return _users > 0


## Another game (main, when the session stops or loads another save): all it knew goes; open views stay open and
## read the new game's pages.
func reset() -> void:
	_pages.clear()
	_used.clear()
	_stale.clear()
	_failed.clear()
	_asked = Vector3i.MAX
	has_player = false
	path.clear()
	destination = null
	note = ""
	if _write_tag > 0:
		_finish_write(false, NO_ANSWER)
	changed.emit()


func _mark(o: Vector3i) -> void:
	_seq += 1
	_stale[o] = _seq


## The page holding `cell` (x, y) on level z: its origin, a multiple of PAGE.
static func page_origin(cell: Vector3i) -> Vector3i:
	return Vector3i(cell.x - posmod(cell.x, PAGE), cell.y - posmod(cell.y, PAGE), cell.z)


## The OMT holding map square `p` (absolute).
static func cell_of_square(p: Vector3i) -> Vector3i:
	return Vector3i(floori(p.x / float(SQUARES_PER_CELL)), floori(p.y / float(SQUARES_PER_CELL)), p.z)


## View `who` (its instance id) shows cells `rect` on level z: the pages under it are read, nearest its middle first
## (the canvas calls this whenever its view moves; an empty rect: it shows nothing now).
func want(rect: Rect2i, z: int, who := 0) -> void:
	if _users == 0 or z < Z_MIN or z > Z_MAX:
		return
	if rect.size.x <= 0 or rect.size.y <= 0:
		_wanted_by.erase(who)
		_merge_wanted()
		return
	var mid := rect.get_center()
	var at := page_origin(Vector3i(mid.x, mid.y, z))
	var far := Vector3i(WANT_SPAN * PAGE, WANT_SPAN * PAGE, 0)
	var lo := page_origin(Vector3i(rect.position.x, rect.position.y, z)).max(at - far)
	var hi := page_origin(Vector3i(rect.end.x - 1, rect.end.y - 1, z)).min(at + far)
	var list: Array[Vector3i] = []
	var y := lo.y
	while y <= hi.y:
		var x := lo.x
		while x <= hi.x:
			if absi(x) <= MAX_XY and absi(y) <= MAX_XY:
				list.append(Vector3i(x, y, z))
			x += PAGE
		y += PAGE
	list.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return _dist2(a, mid) < _dist2(b, mid))
	_wanted_by[who] = list.slice(0, MAX_WANTED)
	_tick += 1
	for o: Vector3i in _wanted_by[who]:
		_used[o] = _tick
	_merge_wanted()
	_ask_next()


func _merge_wanted() -> void:
	_wanted.clear()
	var seen := {}
	for who: int in _wanted_by:
		for o: Vector3i in _wanted_by[who]:
			if not seen.has(o):
				seen[o] = true
				_wanted.append(o)
	for o: Vector3i in _used.keys():   # only what is held or shown keeps its turn
		if not seen.has(o) and not _pages.has(o):
			_used.erase(o)


static func _dist2(o: Vector3i, mid: Vector2i) -> int:
	var dx := o.x + (PAGE >> 1) - mid.x
	var dy := o.y + (PAGE >> 1) - mid.y
	return dx * dx + dy * dy


## What the player knows of `cell` on level z: {name, symbol, color, vision, flags} and {note} when there is one;
## {} when the cell isn't read yet or is unseen without a note.
func info(cell: Vector2i, z: int) -> Dictionary:
	var pg: Page = _pages.get(page_origin(Vector3i(cell.x, cell.y, z)))
	if pg == null:
		return {}
	var lx := posmod(cell.x, PAGE)
	var ly := posmod(cell.y, PAGE)
	var out := {}
	var i := ly * PAGE + lx
	var v := pg.vision[i]
	var k := pg.look[i]
	if v > 0 and k > 0 and k <= pg.looks.size():
		var l: Dictionary = pg.looks[k - 1]
		out = {"name": l["name"], "symbol": l["symbol"], "color": l["color"], "vision": v, "flags": pg.flags[i]}
	elif v > 0:   # seen, but its look didn't fit in the page's answer (truncated): no name
		out = {"name": "", "symbol": "", "color": UNSENT, "vision": v, "flags": pg.flags[i]}
	var n: Variant = pg.notes.get(Vector2i(lx, ly))
	if n != null:
		out["note"] = n
	return out


## The page with origin `o` (page_origin), or null when it isn't read.
func page(o: Vector3i) -> Page:
	return _pages.get(o)


## Whether a page is still to come for what the views show.
func reading() -> bool:
	return _asked != Vector3i.MAX


## A new snapshot (main's _shown): the player's cell; entering a new one reads that page again (what is seen
## changes around the player).
func follow(snap: Snapshot) -> void:
	if snap == null:
		return
	if _write_tag > 0 and Time.get_ticks_msec() - _write_at > WRITE_TIMEOUT_MS:
		_finish_write(false, NO_ANSWER)
	var c := cell_of_square(snap.player_pos)
	if has_player and c == player_cell:
		_ask_next()   # a page that failed is asked again once its wait is over
		return
	has_player = true
	player_cell = c
	if _users > 0:
		_mark(page_origin(c))
		_ask_next()
		changed.emit()


## LiveSession.overmap: a page came (parse_page's Dictionary).
func on_page(r: Dictionary) -> void:
	var o: Vector3i = r.get("origin", Vector3i.MAX)
	var with_path := _asked_path and o == _asked
	var asked_seq := _asked_seq if o == _asked else -1
	if o == _asked:
		_asked = Vector3i.MAX
	if _users == 0:
		return
	if r.get("ok") != true:
		_failed[o] = Time.get_ticks_msec()
		note = r.get("text", "The game couldn't read the map (%s)." % r.get("error", "internal"))
		changed.emit()
		_ask_next()
		return
	note = ""
	_pages[o] = r["page"]
	# read again later when marked after this one was asked (a step meanwhile), or when it is the player's page and
	# came without the path
	if int(_stale.get(o, -1)) <= asked_seq and (o != page_origin(player_cell) or with_path):
		_stale.erase(o)
	_failed.erase(o)
	if with_path:   # asked with the path: none in the answer means no destination
		path.clear()
		if r.has("path"):
			path = r["path"]
		destination = r.get("destination")
	_evict()
	changed.emit()
	_ask_next()


## Slice 2: writes or replaces the note on `cell` (absolute OMT, z the level; an edit is a write over the old one):
## `text` (clean_note: plain, one line, capped at MAX_NOTE; empty refused), `symbol` (ok_symbol), `color` (a
## NOTE_COLORS code), the danger mark and its radius (0..MAX_DANGER_RADIUS). CDDA checks it all again. Returns the
## tag note_done will carry, or 0 when refused here (not connected, a write already out, bad input).
func set_note(cell: Vector3i, text: String, symbol := "N", color := "Y", danger := false, radius := 0) -> int:
	var t := clean_note(text)
	if t.is_empty() or not ok_symbol(symbol) or note_color_index(color) < 0 or radius < 0 \
			or radius > MAX_DANGER_RADIUS or not can_write() or not ok_cell(cell):
		return 0
	return _sent(live.queue_map_note(cell, t, symbol, color, danger, radius if danger else 0), cell)


## Deletes the note on `cell`. The tag note_done will carry, or 0 when refused here.
func delete_note(cell: Vector3i) -> int:
	if not can_write() or not ok_cell(cell):
		return 0
	return _sent(live.queue_map_unnote(cell), cell)


## Whether a note write is out (its note_done hasn't come yet).
func writing() -> bool:
	return _write_tag > 0


## Whether a note can be written now: the bridge takes notes and none is out.
func can_write() -> bool:
	return live != null and live.can_map_notes() and not writing()


func _sent(tag: int, cell: Vector3i) -> int:
	if tag > 0:
		_write_tag = tag
		_write_cell = cell
		_write_at = Time.get_ticks_msec()
	return tag


## LiveSession.events_arrived: the `map_result` for the write out (contracts/events.md; `detail` its tag, `amount`
## 1 done or 0 refused, `text` CDDA's sentence). Done reads the cell's page again, so the note shows as CDDA keeps it.
func on_events(events: Array) -> void:
	if _write_tag == 0:
		return
	for i in mini(events.size(), MAX_EVENTS):
		var ev: Variant = events[i]
		if not ev is Dictionary or (ev as Dictionary).get("kind") != "map_result":
			continue
		var d: Dictionary = ev
		if _int(d.get("detail"), 1, MAX_TAG) != _write_tag:
			continue
		var ok: bool = _int(d.get("amount"), 0, 1) == 1
		var said := "" if ok else _text(d.get("text"), MAX_NOTE).strip_edges()
		_finish_write(ok, said if ok or not said.is_empty() else REFUSED)
		return


func _finish_write(ok: bool, said: String) -> void:
	var tag := _write_tag
	_write_tag = 0
	if ok and _users > 0:
		_mark(page_origin(_write_cell))
		_ask_next()
	note_done.emit(tag, ok, said)


## A note's text as sent: plain (colour tags and control characters out; line breaks and tabs are spaces), on one
## line, capped at MAX_NOTE, trimmed.
static func clean_note(text: String) -> String:
	for brk: String in [char(13) + char(10), char(10), char(13), char(9)]:
		text = text.replace(brk, " ")
	return _text(text, MAX_NOTE).strip_edges()


## A note symbol CDDA reads back as written: one printable ASCII character, not ':' or ';'.
static func ok_symbol(s: String) -> bool:
	return s.length() == 1 and s.unicode_at(0) >= 0x21 and s.unicode_at(0) <= 0x7E and s != ":" and s != ";"


## The index in NOTE_COLORS of colour code `code`, -1 when it isn't one.
static func note_color_index(code: String) -> int:
	for i in NOTE_COLORS.size():
		if NOTE_COLORS[i][0] == code:
			return i
	return -1


## The NOTE_COLORS code of a note's colour as read ("Y", CDDA's default, when none matches).
static func note_color_code(c: Color) -> String:
	for e: Array in NOTE_COLORS:
		if (e[2] as Color).is_equal_approx(c):
			return e[0]
	return "Y"


## Whether `cell` (absolute OMT) is inside the bridge's bounds.
static func ok_cell(cell: Vector3i) -> bool:
	return absi(cell.x) <= MAX_XY and absi(cell.y) <= MAX_XY and cell.z >= Z_MIN and cell.z <= Z_MAX


func _evict() -> void:
	if _pages.size() <= MAX_PAGES:
		return
	var keys := _pages.keys()
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return int(_used.get(a, 0)) < int(_used.get(b, 0)))
	for o: Vector3i in keys.slice(0, _pages.size() - MAX_PAGES):
		_pages.erase(o)
		_used.erase(o)


func _ask_next() -> void:
	if _asked != Vector3i.MAX and (live == null or not live.overmap_pending()):
		_asked = Vector3i.MAX   # the session forgot it (the game stopped, a timeout): nothing will answer
	if _users == 0 or _asked != Vector3i.MAX:
		return
	if live == null or not live.has_overmap():
		if note != NO_BRIDGE:
			note = NO_BRIDGE
			changed.emit()
		return
	if live.overmap_pending():
		return
	var mine := page_origin(player_cell)
	var now := Time.get_ticks_msec()
	var pick := Vector3i.MAX
	if _stale.has(mine) and has_player and now - int(_failed.get(mine, now - RETRY_MS)) >= RETRY_MS:
		pick = mine
	else:
		for o in _wanted:
			if (not _pages.has(o) or _stale.has(o)) and now - int(_failed.get(o, now - RETRY_MS)) >= RETRY_MS:
				pick = o
				break
	if pick == Vector3i.MAX:
		return
	_asked_path = pick == mine and has_player
	if live.query_overmap(pick, _asked_path) > 0:
		_asked = pick
		_asked_seq = _seq


## The bridge's answer text for query `id` (contracts/overmap.md), checked: {ok true, origin, page: Page, path?,
## destination?} or {ok false, origin, error, text?}; {} when it can't be read at all.
static func parse_page(text: Variant, id: int, asked: Vector3i) -> Dictionary:
	if not text is String or (text as String).is_empty() or (text as String).length() > MAX_RESULT_BYTES:
		return {}
	var j := JSON.new()   # parse() returns its error quietly
	if j.parse(text) != OK or not j.data is Dictionary:
		return {}
	var d: Dictionary = j.data
	if id < 1 or _int(d.get("id"), 1, MAX_QUERY_ID) != id or d.get("kind") != "overmap" or not d.get("ok") is bool:
		return {}
	if d["ok"] != true:
		var e: Variant = d.get("error")
		var out := {"ok": false, "origin": asked, "error": e if e is String and e in ERRORS else "internal"}
		var said := _text(d.get("text"), MAX_NOTE)
		if not said.is_empty():
			out["text"] = said
		return out
	if _cell3(d.get("origin")) != asked:
		return {}
	var p := Page.new()
	p.origin = asked
	# the bridge's looks[0] is always the unseen cell; the page keeps the others, so a cell's look k is looks[k - 1]
	var looks: Variant = d.get("looks")
	if not looks is Array or (looks as Array).is_empty() or (looks as Array).size() > MAX_LOOKS:
		return {}
	for l: Variant in (looks as Array).slice(1):
		if not l is Dictionary:
			return {}
		var ld: Dictionary = l
		p.looks.append({"name": _text(ld.get("name"), MAX_NAME), "symbol": _symbol(ld.get("sym"), ""),
				"color": _color(ld.get("color"))})
	p.look = _ints(d.get("look"), 0, p.looks.size())
	p.vision = PackedByteArray(Array(_ints(d.get("vision"), 0, MAX_VISION)))
	p.flags = _ints(d.get("flags"), 0, 0x7FFFFFFF)
	if p.look.size() != CELLS or p.vision.size() != CELLS or p.flags.size() != CELLS:
		return {}
	var notes: Variant = d.get("notes", [])
	if not notes is Array or (notes as Array).size() > MAX_NOTES:
		return {}
	for n: Variant in notes:   # a note that isn't whole or isn't on this page is left out (it never hides the page)
		var nd: Dictionary = n if n is Dictionary else {}
		var at: Variant = nd.get("at")
		if not at is Array or (at as Array).size() != 2:
			continue
		var lx: Variant = _int(at[0], asked.x, asked.x + PAGE - 1)
		var ly: Variant = _int(at[1], asked.y, asked.y + PAGE - 1)
		var r: Variant = _int(nd.get("radius", 0), 0, 1 << 30)
		if lx == null or ly == null or r == null:
			continue
		p.notes[Vector2i(lx - asked.x, ly - asked.y)] = {"text": _text(nd.get("text"), MAX_NOTE),
				"symbol": _symbol(nd.get("sym"), "N"), "color": _color(nd.get("color")),
				"danger": nd.get("danger") == true, "radius": mini(r, MAX_RADIUS)}
	p.truncated = d.get("truncated") == true
	var out := {"ok": true, "origin": asked, "page": p}
	if d.has("path"):   # only with a destination: {to, cells (x, y, z flat, from the player's end), more}
		var pd: Dictionary = d["path"] if d["path"] is Dictionary else {}
		var dest := _cell3(pd.get("to"))
		var raw: Variant = pd.get("cells", [])
		if dest == Vector3i.MAX or not raw is Array or (raw as Array).size() > MAX_PATH * 3 \
				or (raw as Array).size() % 3 != 0:
			return {}
		var pts: Array[Vector3i] = []
		var a: Array = raw
		for k in range(0, a.size(), 3):
			var c := _cell3(a.slice(k, k + 3))
			if c == Vector3i.MAX:
				return {}
			pts.append(c)
		out["path"] = pts
		out["destination"] = dest
	return out


## An absolute cell [x, y, z] in range, else Vector3i.MAX.
static func _cell3(v: Variant) -> Vector3i:
	if not v is Array or (v as Array).size() != 3:
		return Vector3i.MAX
	var x: Variant = _int(v[0], -MAX_XY, MAX_XY)
	var y: Variant = _int(v[1], -MAX_XY, MAX_XY)
	var z: Variant = _int(v[2], Z_MIN, Z_MAX)
	if x == null or y == null or z == null:
		return Vector3i.MAX
	return Vector3i(x, y, z)


## The ints of a CELLS-long list in [lo, hi]; a shorter result when one isn't.
static func _ints(v: Variant, lo: int, hi: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if not v is Array or (v as Array).size() != CELLS:
		return out
	out.resize(CELLS)
	var a: Array = v
	for i in CELLS:
		var n: Variant = _int(a[i], lo, hi)
		if n == null:
			return PackedInt32Array()
		out[i] = n
	return out


static func _int(v: Variant, lo: int, hi: int) -> Variant:
	if v is int:
		return v if v >= lo and v <= hi else null
	if v is float and is_finite(v) and v == floorf(v) and v >= lo and v <= hi:
		return int(v)
	return null


## Text from the game (a save's note may be anyone's): plain, capped, on one line (Snapshot.plain_text keeps the
## line and paragraph separators, which a Label breaks on).
static func _text(v: Variant, cap: int) -> String:
	return Snapshot.plain_text(v, cap).replace(char(0x2028), " ").replace(char(0x2029), " ").replace(char(0x85), " ")


## A symbol: its first glyph, control characters out (`none` when there is none: CDDA's line-drawing symbols come
## as "").
static func _symbol(v: Variant, none: String) -> String:
	var s := _text(v, MAX_SYMBOL).strip_edges()
	return s.substr(0, 1) if not s.is_empty() else none


## A CDDA colour name (c_light_green, i_red, red_white, ...) as its foreground; light gray when unknown.
static func _color(v: Variant) -> Color:
	var c := CddaText.parse_color(v if v is String and (v as String).length() <= 32 else "")
	return Color(c[0]) if not c.is_empty() else Color(CddaText.COLORS["light_gray"])
