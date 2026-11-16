class_name ClassicView
extends Control
## Block G8: the classic overlay, a dev panel for parity checks between the 3D view and what CDDA sees. It draws
## the snapshot around the player as CDDA's own ASCII view: each square's symbol and colour from the id tables, in
## CDDA's order (the player @, creatures, the top item of a pile or a corpse, furniture, known traps, terrain);
## AUTO_WALL_SYMBOL terrain (walls, fences) joins its neighbours of the same connect group with line characters as
## CDDA does; squares never seen stay blank and remembered ones are dimmed. Not drawn yet: fields (the id tables'
## level colours aren't read by the client) and vehicles (no part per square in the snapshot). Toggled with F3
## (`classic_view`), off by default; read-only. Symbols are game data: one printable character each (else "?"),
## drawn with draw_char into fixed cells, never parsed as markup.

const RX := 30          # squares left and right of the player
const RY := 15          # squares above and below
const CELL := Vector2(9, 15)
const FONT_SIZE := 13
const PAD := 6.0
const HEAD_H := 18.0
const DIM := 0.55       # remembered squares: this much darker
const BACK := Color(0, 0, 0, 0.82)
const PLAYER := Color(1, 1, 1)
const UNKNOWN := "?"
## Line characters by the neighbours joined: 1 north, 2 east, 4 south, 8 west (CDDA's LINE_ symbols).
const LINES := {1: "│", 4: "│", 5: "│", 2: "─", 8: "─", 10: "─", 3: "└", 6: "┌", 12: "┐", 9: "┘", 7: "├",
		11: "┴", 13: "┤", 14: "┬", 15: "┼"}
const STEPS := [Vector3i(0, -1, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(-1, 0, 0)]   # N E S W

var snapshot: Snapshot
var tables: IdTables
var rows: Array = []    # cells(): [char, Color] per square, north row first


func _init() -> void:
	name = "ClassicView"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	var sz := Vector2((2 * RX + 1) * CELL.x, (2 * RY + 1) * CELL.y) + Vector2(2 * PAD, 2 * PAD + HEAD_H)
	custom_minimum_size = sz
	size = sz
	position = Vector2(-sz.x - 12.0, 36.0)


## The newest snapshot and tables; redrawn now when shown, else when it next shows.
func show_world(snap: Snapshot, t: IdTables) -> void:
	snapshot = snap
	tables = t
	if visible:
		rebuild()


## F3: shows or hides it (rebuilt when it shows).
func toggle() -> void:
	visible = not visible
	if visible:
		rebuild()


func rebuild() -> void:
	rows = cells(snapshot, tables, snapshot.player_pos if snapshot != null else Vector3i.ZERO)
	queue_redraw()


## [char, Color] per square around `centre` (its level), rows north to south, RX / RY squares each way.
static func cells(snap: Snapshot, t: IdTables, centre: Vector3i, rx := RX, ry := RY) -> Array:
	var out: Array = []
	if snap == null or t == null:
		return out
	rx = clampi(rx, 0, RX)
	ry = clampi(ry, 0, RY)
	for dy in range(-ry, ry + 1):
		var row: Array = []
		for dx in range(-rx, rx + 1):
			row.append(cell(snap, t, centre + Vector3i(dx, dy, 0)))
		out.append(row)
	return out


## One square as CDDA's ASCII view draws it: [char, Color]; [" ", ...] when never seen or not in the snapshot.
static func cell(snap: Snapshot, t: IdTables, p: Vector3i) -> Array:
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return [" ", PLAYER]
	var l := CddaCoords.ms_to_local(p)
	var i := l.y * CddaCoords.SEEX + l.x
	var vis: int = sm.vis[i] if i < sm.vis.size() else 2
	if vis == 0:
		return [" ", PLAYER]
	var out: Array = _what(snap, t, sm, i, p, vis)
	if vis == 1:
		out[1] = (out[1] as Color).darkened(DIM)
	return out


static func _what(snap: Snapshot, t: IdTables, sm: Snapshot.Submap, i: int, p: Vector3i, vis: int) -> Array:
	if p == snap.player_pos:
		return ["@", PLAYER]
	if vis >= 2:
		var c := snap.creature_at(p)
		if c != null:
			if c.kind == Snapshot.Creature.MONSTER:
				return _def(t.def_at("mtype", c.type))
			var npc := {Snapshot.Creature.HOSTILE: "c_red", Snapshot.Creature.FRIENDLY: "c_light_green"}
			return ["@", CddaPalette.fg(npc.get(c.attitude, "c_white"))]
	var it := _pile_top(sm, i)
	if it[0] != 0:
		return _def(t.def_at("itype", it[0]))
	if it[1] != 0:   # a corpse alone: CDDA's %, in the creature's colour
		var m := t.def_at("mtype", it[1])
		return ["%", CddaPalette.fg(m.color if m != null else "c_red")]
	var f: int = sm.furn[i] if i < sm.furn.size() else 0
	if f != 0:
		return _def(t.def_at("furn", f))
	var tr: int = sm.trap[i] if i < sm.trap.size() else 0
	if tr != 0:
		return _def(t.def_at("trap", tr))
	var ter: int = sm.ter[i] if i < sm.ter.size() else 0
	var d := t.def_at("ter", ter)
	var out := _def(d)
	if d != null and d.has("AUTO_WALL_SYMBOL"):
		var joins := 0
		for k in STEPS.size():
			var nd := _ter_def(snap, t, p + STEPS[k])
			if nd != null and (d.connects_to & nd.groups) != 0:
				joins |= 1 << k
		if LINES.has(joins):
			out[0] = LINES[joins]
	return out


## [itype of the pile's top item, mtype of its largest corpse] on tile `i`, zeros when none.
static func _pile_top(sm: Snapshot.Submap, i: int) -> Array:
	var p := sm.items
	for k in range(0, p.size() - Snapshot.PILE_STRIDE + 1, Snapshot.PILE_STRIDE):
		if p[k] == i:
			return [p[k + 2], p[k + Snapshot.PILE_CORPSE]]
	return [0, 0]


static func _ter_def(snap: Snapshot, t: IdTables, p: Vector3i) -> IdTables.Def:
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return null
	var l := CddaCoords.ms_to_local(p)
	var i := l.y * CddaCoords.SEEX + l.x
	if i >= sm.ter.size() or (i < sm.vis.size() and sm.vis[i] == 0):
		return null   # as CDDA: only squares the player knows join
	return t.def_at("ter", sm.ter[i])


## A definition's symbol and colour: [char, Color]; "?" in grey for a missing one.
static func _def(d: IdTables.Def) -> Array:
	if d == null:
		return [UNKNOWN, CddaPalette.DEFAULT]
	return [glyph(d.symbol), CddaPalette.fg(d.color)]


## One printable character for a symbol from the tables (colour tags and control characters dropped), else "?".
static func glyph(sym: String) -> String:
	var s := Snapshot.plain_text(CddaText.plain(sym.left(64)), 1)   # tags out first: plain_text cuts before
	return s if s.length() == 1 else UNKNOWN


## The text of the rows (no colours): what the tests and a parity diff read.
func text() -> String:
	var lines := PackedStringArray()
	for row: Array in rows:
		var s := ""
		for c: Array in row:
			s += c[0]
		lines.append(s)
	return "\n".join(lines)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BACK)
	var font := ThemeDB.fallback_font
	var z := snapshot.player_pos.z if snapshot != null else 0
	draw_string(font, Vector2(PAD, PAD + FONT_SIZE), "CDDA classic view (%s), level %d" % [
			InputActions.key_of(&"classic_view"), z], HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 1, Color(0.8, 0.8, 0.8))
	var top := Vector2(PAD, PAD + HEAD_H)
	for y in rows.size():
		var row: Array = rows[y]
		for x in row.size():
			var c: Array = row[x]
			if c[0] == " ":
				continue
			var at := top + Vector2(x * CELL.x, y * CELL.y + FONT_SIZE - 2)
			draw_char(font, at, c[0], FONT_SIZE, c[1])
