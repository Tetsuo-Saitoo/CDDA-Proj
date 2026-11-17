extends RefCounted
## Block G8: ClassicView, CDDA's ASCII view of the snapshot (symbols and colours from the id tables, CDDA's draw
## order, joined walls, unseen blank, remembered dimmed, hostile symbols cleaned). Run by run_tests.gd.

var _check: Callable


func run(check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("classic view")
	var snap := Snapshot.from_data(data)
	if not snap.is_valid() or not tables.is_valid():
		_check.call(false, "classic view: the mock town and tables load (%s %s)" % [snap.error, tables.error])
		return
	var p := snap.player_pos
	var rows := ClassicView.cells(snap, tables, p)
	var mid: Array = rows[ClassicView.RY][ClassicView.RX] if rows.size() == 2 * ClassicView.RY + 1 else []
	_check.call(rows.size() == 2 * ClassicView.RY + 1 and (rows[0] as Array).size() == 2 * ClassicView.RX + 1
			and not mid.is_empty() and mid[0] == "@", "classic view: %d x %d squares, the player @ in the middle"
			% [rows.size(), (rows[0] as Array).size() if not rows.is_empty() else 0])
	_check.call(ClassicView.glyph("") == "?" and ClassicView.glyph("<color_red>#</color>") == "#"
			and ClassicView.glyph(char(7)) == "?" and ClassicView.glyph("ab") == "a" and ClassicView.glyph("\n") == "?",
			"classic view: a table symbol is one printable character, colour tags dropped, else ?")
	# hand-laid squares two rows north of the player: a wall run west-east with one going north at its east end
	var wall := tables.index_of("ter", "t_wall")
	var floor_id := tables.index_of("ter", "t_floor")
	var at := func(q: Vector3i) -> Array:
		var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(q))
		var l := CddaCoords.ms_to_local(q)
		return [sm, l.y * CddaCoords.SEEX + l.x]
	var lay := func(q: Vector3i, ter: int, vis: int) -> void:
		var a: Array = at.call(q)
		var sm: Snapshot.Submap = a[0]
		var i: int = a[1]
		sm.ter[i] = ter
		sm.furn[i] = 0
		if sm.trap.size() > i:
			sm.trap[i] = 0
		if sm.vis.size() > i:
			sm.vis[i] = vis
		var piles := PackedInt32Array()   # no item on it
		for k in range(0, sm.items.size() - Snapshot.PILE_STRIDE + 1, Snapshot.PILE_STRIDE):
			if sm.items[k] != i:
				piles.append_array(sm.items.slice(k, k + Snapshot.PILE_STRIDE))
		sm.items = piles
	var y := p + Vector3i(0, -6, 0)
	for dx in range(-4, 5):
		for dy in range(-2, 3):
			lay.call(y + Vector3i(dx, dy, 0), floor_id, 2)
	for dx in range(-2, 3):
		lay.call(y + Vector3i(dx, 0, 0), wall, 2)
	lay.call(y + Vector3i(2, -1, 0), wall, 2)
	var ch := func(q: Vector3i) -> String: return ClassicView.cell(snap, tables, q)[0]
	var line := [ch.call(y + Vector3i(-2, 0, 0)), ch.call(y), ch.call(y + Vector3i(2, 0, 0)), ch.call(y + Vector3i(2, -1, 0))]
	_check.call(wall > 0 and line == ["─", "─", "┘", "│"],
			"classic view: walls join their neighbours as CDDA's line characters (%s)" % [line])
	lay.call(y + Vector3i(-3, 0, 0), wall, 0)   # never seen: blank, and nothing joins to it
	var flo := ClassicView.cell(snap, tables, y + Vector3i(0, 1, 0))
	lay.call(y + Vector3i(0, 1, 0), floor_id, 1)
	var old := ClassicView.cell(snap, tables, y + Vector3i(0, 1, 0))
	var fd := tables.def_at("ter", floor_id)
	_check.call(ch.call(y + Vector3i(-3, 0, 0)) == " " and ch.call(y + Vector3i(-2, 0, 0)) == "─"
			and flo[0] == fd.symbol and flo[1] == CddaPalette.fg(fd.color) and old[0] == flo[0]
			and (old[1] as Color).v < (flo[1] as Color).v,
			"classic view: never seen is blank (and joins nothing), remembered is dimmed")
	# draw order: an item over furniture over terrain, a corpse alone as %
	var q := y + Vector3i(-1, 1, 0)
	var a: Array = at.call(q)
	var sm: Snapshot.Submap = a[0]
	var i: int = a[1]
	var chair := tables.index_of("furn", "f_chair")
	sm.furn[i] = chair
	var on_furn: String = ch.call(q)
	var k := InputActions.prompt_of(&"use_held")
	var said := [ContextPrompt.text(snap, tables, q, HudSettings.MENU_HOLD),
			ContextPrompt.text(snap, tables, q, HudSettings.MENU_LIST),
			ContextPrompt.text(snap, tables, y, HudSettings.MENU_HOLD),
			ContextPrompt.text(null, tables, q, HudSettings.MENU_HOLD)]
	var cn := CddaText.plain(tables.def_at("furn", chair).name).capitalize()
	_check.call(chair > 0 and said == ["%s\n%s use   hold %s: choices" % [cn, k, k], "%s\n%s use" % [cn, k], "", ""],
			"context prompt: the furniture you face and what E does there, none on bare floor (%s)" % [said])
	# With the tables' examine ids (lead-bridge): E's word from the id; terrain only with an action.
	var cd := tables.def_at("furn", chair)
	var ya: Array = at.call(y)
	var td := tables.def_at("ter", (ya[0] as Snapshot.Submap).ter[ya[1]])
	var keep_known := tables.has_examine
	tables.has_examine = true
	cd.examine = "workbench"
	var crafted := ContextPrompt.text(snap, tables, q, HudSettings.MENU_LIST)
	cd.examine = ""
	var plain := ContextPrompt.text(snap, tables, q, HudSettings.MENU_LIST)
	var bare := ContextPrompt.text(snap, tables, y, HudSettings.MENU_LIST)
	td.examine = "water_source"
	var spring := ContextPrompt.text(snap, tables, y, HudSettings.MENU_HOLD)
	td.examine = ""
	tables.has_examine = keep_known
	var tn := CddaText.plain(td.name).strip_edges().left(ContextPrompt.MAX_NAME).capitalize()
	_check.call(crafted == "%s\n%s craft" % [cn, k] and plain == "%s\n%s examine" % [cn, k] and bare == ""
			and spring == "%s\n%s drink   hold %s: choices" % [tn, k, k] and ContextPrompt.word_for("odd", true) == "examine"
			and ContextPrompt.word_for("fireplace", false) == "use",
			"context prompt: E's word from the examine id (else examine; no ids: use); terrain only with an action %s"
			% [[crafted, plain, bare, spring]])
	var rock := tables.index_of("itype", "rock")
	sm.items.append_array(PackedInt32Array([i, 1, rock, 0, 0, 0, 0, 0]))
	var on_item: String = ch.call(q)
	var zed := tables.index_of("mtype", "mon_zombie")
	var q2 := y + Vector3i(1, 1, 0)
	var a2: Array = at.call(q2)
	(a2[0] as Snapshot.Submap).items.append_array(PackedInt32Array([a2[1], 1, 0, 0, 0, 0, zed, 0]))
	_check.call(chair > 0 and rock > 0 and on_furn == ClassicView.glyph(tables.def_at("furn", chair).symbol)
			and on_item == ClassicView.glyph(tables.def_at("itype", rock).symbol) and ch.call(q2) == "%",
			"classic view: an item over furniture over terrain; a corpse alone is %% (%s %s %s)" % [on_furn, on_item, ch.call(q2)])
	# one pass indexes each submap's piles once; both piles still show
	var pass_rows := ClassicView.cells(snap, tables, p)
	var r5: Array = pass_rows[ClassicView.RY - 5]
	_check.call(r5[ClassicView.RX - 1][0] == on_item and r5[ClassicView.RX + 1][0] == "%",
			"classic view: a whole pass shows each pile from the per-submap index (%s %s)"
			% [r5[ClassicView.RX - 1][0], r5[ClassicView.RX + 1][0]])
	# the panel: hidden at first, built when shown, its text one line per row
	var v := ClassicView.new()
	v.show_world(snap, tables)
	var idle := v.rows.is_empty()
	v.toggle()
	var lines := v.text().split("\n")
	_check.call(idle and v.visible and lines.size() == 2 * ClassicView.RY + 1
			and lines[ClassicView.RY].substr(ClassicView.RX, 1) == "@" and not InputActions.info(&"classic_view").is_empty(),
			"classic view: hidden until F3, then the rows around the player (%d lines)" % lines.size())
	v.toggle()
	v.show_world(null, tables)
	v.toggle()
	_check.call(v.rows.is_empty(), "classic view: no snapshot, nothing drawn")
	v.free()
