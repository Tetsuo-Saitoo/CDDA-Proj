class_name ViseBench
extends PanelContainer
## Gun modification with a bench vise on the flat screen (V2, user 2026-11-17; lead-vr's V1 is the VR side). E on a
## bench vise in reach with a gun wielded ("Clamp the gun") draws the gun lying in the vise's jaws and shows this
## panel: the gun's installed mods (Take off) and the carried gunmods CDDA judged (wielded_gun `fits`: Fit, with its
## odds, or its reason). Only the client shows the gun in the vise: CDDA still wields it and nothing about the vise
## goes to CDDA. Esc (BackOut "vise"), "Take the gun back", E on the vise again, walking off (the vise out of reach:
## Vise.near) or the gun no longer wielded end it (released). Fitting and taking off go through ItemActions.mod_add /
## mod_remove, the same as E and the Tab view (GunModFit). V3: a fit from here names the vise (mod_add's vise), so CDDA
## rolls with Vise.odds (+20, half the risk); the panel shows those odds.

signal released(why: String)

const WIDTH := 380.0
const MAX_ROWS := 16             # rows of each list shown
const MAX_STATUS := 200
const BAD := Color(1.0, 0.5, 0.45)
const DIM := Color(0.65, 0.65, 0.7)
const MOVED := "You step away from the vise and take your gun back."
const NOT_HELD := "Your gun isn't in your hands any more."
const BACK := "Take the gun back"

var actions: ItemActions
var world: WorldView             # its snapshot and id tables are read when needed
var model_parent: Node3D         # where the gun in the vise is drawn (main: the world)
## (set_to: int) -> int: sets the mouse mode when set_to >= 0, returns the current one (tests; not set: Input's).
var mouse_hook := Callable()
## (vise uid) -> Variant: where that vise holds a gun now (main: Vise.jaws), checked on each snapshot.
var jaws := Callable()

var vise_uid := -1
var gun: ItemRef
var model: Node3D                # the gun drawn in the jaws (WeaponViewmodel.build), null when not drawn
var status := ""
var _shape := ""
var _across := Vector3.RIGHT
var _mods_sig := ""
var _rows_sig := ""
var _prev_mouse := -1
var _title: Label
var _list: VBoxContainer
var _status: Label
var _buttons := {}               # uid -> its row's Fit / Take off button (tests)


func _init() -> void:
	name = "ViseBench"
	visible = false
	set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	custom_minimum_size = Vector2(WIDTH, 0)
	position = Vector2(-WIDTH - 24.0, -160.0)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.08, 0.1, 0.92)
	bg.set_content_margin_all(10)
	add_theme_stylebox_override("panel", bg)
	var v := VBoxContainer.new()
	add_child(v)
	_title = _label("", Color.WHITE)
	v.add_child(_title)
	_list = VBoxContainer.new()
	v.add_child(_list)
	_status = _label("", DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(WIDTH - 20.0, 0)
	v.add_child(_status)
	var back := Button.new()
	back.name = "Back"
	back.text = "%s (Esc)" % BACK
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(func() -> void: release())
	v.add_child(back)


## The gun is in the vise.
func clamped() -> bool:
	return vise_uid > 0 and gun != null


## Clamps wielded gun `g` in bench vise `vise` (one Vise.near lists): draws it at `at` (the jaws, world; not drawn when
## not a Vector3) with its barrel along `across`, frees the mouse and shows the panel. False when it can't.
func clamp_gun(vise: int, g: ItemRef, at: Variant, across := Vector3.RIGHT) -> bool:
	var snap := _snap()
	if clamped() or snap == null or g == null or not stay_reason(snap, _tables(), vise, g).is_empty():
		return false
	vise_uid = vise
	gun = g.duplicate_ref()
	status = ""
	_mods_sig = ""
	_rows_sig = ""
	var d: IdTables.Def = _tables().def_at("itype", gun.type) if _tables() != null else null
	_shape = WeaponViewmodel.shape_for(d)
	_across = across
	_title.text = "%s in the vise" % InventoryModel.clean(gun.display_name(_tables())).capitalize()
	place(at, across)
	_prev_mouse = _mouse()
	_mouse(Input.MOUSE_MODE_VISIBLE)
	visible = true
	refresh()
	return true


## Ends it (`why`, when given, is said by main): the gun's model goes, the mouse comes back as it was.
func release(why := "") -> void:
	if not clamped():
		return
	vise_uid = -1
	gun = null
	visible = false
	if model != null:
		model.queue_free()
		model = null
	if _prev_mouse >= 0 and _mouse() == Input.MOUSE_MODE_VISIBLE:
		_mouse(_prev_mouse)
	_prev_mouse = -1
	released.emit(why)


## Puts the gun's model at `at` (the vise's jaws), barrel along `across`; none when `at` isn't a finite Vector3.
func place(at: Variant, across := Vector3.RIGHT) -> void:
	if not at is Vector3 or not (at as Vector3).is_finite() or model_parent == null or _shape.is_empty() \
			or _shape in ["melee", "item"]:
		if model != null:
			model.visible = false
		return
	if model == null:
		model = WeaponViewmodel.build(_shape)
		model.name = "ViseGun"
		model_parent.add_child(model)
		_mods_sig = ""
	var dir := Vector3(across.x, 0.0, across.z)
	if not dir.is_finite() or dir.length() < 0.01:
		dir = Vector3.RIGHT
	model.global_transform = Transform3D(Basis.looking_at(dir.normalized(), Vector3.UP), at)
	model.visible = true
	_dress()


## Every new snapshot (main): ends it when the vise is out of reach or the gun not wielded (stay_reason), else shows
## the gun's mods and the carried gunmods as they are now.
func on_snapshot() -> void:
	if not clamped():
		return
	var snap := _snap()
	var why := stay_reason(snap, _tables(), vise_uid, gun) if snap != null else MOVED
	if not why.is_empty():
		release(why)
		return
	if jaws.is_valid():
		place(jaws.call(vise_uid), _across)   # the vise's pile may have been drawn again
	refresh()


## Why gun `g` can't stay in vise `vise` now: "" when it can (the vise lies within reach: Vise.near; `g` is the
## wielded gun).
static func stay_reason(snap: Snapshot, tables: IdTables, vise: int, g: ItemRef) -> String:
	if snap == null or vise <= 0 or not vise in Vise.near(snap, tables):
		return MOVED
	if not GunModFit.is_wielded_gun(g, snap):
		return NOT_HELD
	return ""


## What the panel lists for wielded `g`: {mods: [{uid, type, name, location, fixed, pending}] (installed: wielded_gun
## `mods`), fits: [{uid, type, name, item (ItemRef), ok, chance, risk, reason, pending}] (carried gunmods CDDA judged:
## `fits`, whose rows are carried)}, each at most MAX_ROWS.
static func entries(snap: Snapshot, tables: IdTables, acts: ItemActions, g: ItemRef) -> Dictionary:
	var mods: Array[Dictionary] = []
	var fits: Array[Dictionary] = []
	if snap == null or not GunModFit.is_wielded_gun(g, snap):
		return {"mods": mods, "fits": fits}
	for m: Dictionary in GunModFit.mods_on(snap, g).slice(0, MAX_ROWS):
		mods.append({"uid": m["uid"], "type": m["type"], "name": _name(tables, m["type"]),
				"location": InventoryModel.clean(str(m["location"])), "fixed": int(m["flags"]) & GunModFit.IRREMOVABLE != 0,
				"pending": acts != null and acts.pending(m["uid"]) != ""})
	var fs: Variant = snap.player_gun.get("fits")
	if fs is Array:
		var c := snap.carried
		for f: Variant in (fs as Array).slice(0, Snapshot.MAX_GUN_FITS):
			if fits.size() >= MAX_ROWS:
				break
			if not f is Dictionary or not (f as Dictionary).get("ok") is bool:
				continue
			var uid: Variant = (f as Dictionary).get("uid")
			for i in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
				if c[i] != uid or c[i] == g.uid:
					continue
				var it := ItemRef.on_player(c[i], int(c[i + 1]), int(c[i + 2]), int(c[i + 3]), int(c[i + 4]),
						snap.player_pos)
				fits.append({"uid": it.uid, "type": it.type, "name": _name(tables, it.type), "item": it,
						"ok": f["ok"], "chance": clampi(f["chance"], 0, 100) if f.get("chance") is int else 100,
						"risk": clampi(f["risk"], 0, 100) if f.get("risk") is int else 0,
						"reason": InventoryModel.clean(str(f.get("reason", "")), MAX_STATUS),
						"pending": acts != null and acts.pending(it.uid) != ""})
				break
	return {"mods": mods, "fits": fits}


## Rebuilds the lists when what they show changed; the gun's model follows its mods.
func refresh() -> void:
	if not clamped():
		return
	_dress()
	var e := entries(_snap(), _tables(), actions, gun)
	var sig := var_to_str([e["mods"].map(func(m: Dictionary) -> Array: return [m["uid"], m["pending"]]),
			e["fits"].map(func(f: Dictionary) -> Array: return [f["uid"], f["ok"], f["chance"], f["risk"], f["reason"],
			f["pending"]])])
	_status.text = status
	_status.add_theme_color_override("font_color", BAD if status != "" else DIM)
	if sig == _rows_sig:
		return
	_rows_sig = sig
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_buttons.clear()
	_list.add_child(_label("On the gun:", DIM))
	if (e["mods"] as Array).is_empty():
		_list.add_child(_label("   (no mods)", DIM))
	for m: Dictionary in e["mods"]:
		var b: Button = null
		if not m["fixed"]:
			b = _button("Take off", take_off.bind(m["uid"]), m["pending"])
		_list.add_child(_row("%s (%s)%s" % [m["name"], m["location"], ", fixed" if m["fixed"] else ""], Color.WHITE, b))
		if b != null:
			_buttons[m["uid"]] = b
	_list.add_child(_label("Your gunmods:", DIM))
	if (e["fits"] as Array).is_empty():
		_list.add_child(_label("   (none carried)", DIM))
	for f: Dictionary in e["fits"]:
		var line: String = f["name"]
		if not f["ok"]:
			line += ": " + (str(f["reason"]) if str(f["reason"]) != "" else "doesn't fit")
		elif int(f["chance"]) < 100:
			var o := Vise.odds(f["chance"], f["risk"])   # V3: the vise's better odds (the fork applies them)
			line += ": %d%% (%d%% risk of damage) with the vise" % [o.x, o.y] if o.x < 100 else ": sure, with the vise"
		var b := _button("Fit", fit_mod.bind(f["uid"]), f["pending"] or not f["ok"])
		_list.add_child(_row(line, Color.WHITE if f["ok"] else BAD, b))
		_buttons[f["uid"]] = b


## Fits carried gunmod `uid` (a Fit button): ItemActions.mod_add. "mod_add" when sent.
func fit_mod(uid: int) -> String:
	if not clamped() or actions == null:
		return ""
	for f: Dictionary in entries(_snap(), _tables(), actions, gun)["fits"]:
		if f["uid"] != uid:
			continue
		var why := GunModFit.refusal(_snap(), uid, InventoryModel.clean(gun.display_name(_tables())))
		if why != "":
			return _said(why)
		var vt := Vise.type_of(_tables())   # V3: named, the vise gives better odds (the fork checks it)
		if not actions.mod_add(f["item"], gun, vise_uid if vt > 0 else 0, vt if vt > 0 else 0):
			return _said("You can't fit that now.")
		_said(fitting_line(f["name"], f["chance"], f["risk"], vt > 0), false)
		refresh()
		return "mod_add"
	return ""


## Takes installed mod `uid` off (a Take off button): ItemActions.mod_remove. "mod_remove" when sent.
func take_off(uid: int) -> String:
	if not clamped() or actions == null:
		return ""
	for m: Dictionary in entries(_snap(), _tables(), actions, gun)["mods"]:
		if m["uid"] != uid:
			continue
		if m["fixed"]:
			return _said("The %s can't be taken off." % m["name"])
		if not actions.mod_remove(uid, m["type"], gun):
			return _said("You can't take that off now.")
		_said("Taking off the %s." % m["name"], false)
		refresh()
		return "mod_remove"
	return ""


## The line once fitting `mod_name` is asked for: CDDA's odds (`fits` chance and risk), the vise's (Vise.odds) when
## `with_vise`; none at 100 %.
static func fitting_line(mod_name: String, chance: int, risk: int, with_vise: bool) -> String:
	var o := Vise.odds(chance, risk) if with_vise else Vector2i(clampi(chance, 0, 100), clampi(risk, 0, 100))
	return GunModFit.FITTING_ODDS % [mod_name, o.x, o.y] if o.x < 100 else GunModFit.FITTING % mod_name


## ItemActions refused a fit or take-off: its reason on the panel.
func on_refused(_item: ItemRef, op: String, reason: String) -> void:
	if clamped() and op in ["mod_add", "mod_remove"]:
		_said(InventoryModel.clean(reason, MAX_STATUS))
		refresh()


## The button on row `uid` (tests), null if none.
func button_of(uid: int) -> Button:
	return _buttons.get(uid)


# --- inside ---

func _said(text: String, bad := true) -> String:
	status = InventoryModel.clean(text, MAX_STATUS)
	_status.text = status
	_status.add_theme_color_override("font_color", BAD if bad else Color.WHITE)
	return ""


func _dress() -> void:
	if model == null:
		return
	var mods := GunModFit.mods_on(_snap(), gun)
	var sig := var_to_str(mods)
	if sig != _mods_sig:
		_mods_sig = sig
		GunMods.dress(model, _shape, mods)


func _snap() -> Snapshot:
	return world.snapshot if world != null else null


func _tables() -> IdTables:
	return world.tables if world != null else null


func _mouse(set_to := -1) -> int:
	if mouse_hook.is_valid():
		return mouse_hook.call(set_to)
	if set_to >= 0:
		Input.mouse_mode = set_to as Input.MouseMode
	return Input.mouse_mode


static func _name(tables: IdTables, t: int) -> String:
	var d: IdTables.Def = tables.def_at("itype", t) if tables != null else null
	return InventoryModel.clean(d.name if d != null and not d.name.is_empty() else "mod")


static func _row(text: String, color: Color, b: Button) -> HBoxContainer:
	var h := HBoxContainer.new()
	var l := _label(text, color)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	h.add_child(l)
	if b != null:
		h.add_child(b)
	return h


static func _button(text: String, on_press: Callable, off: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.disabled = off
	b.pressed.connect(func() -> void: on_press.call())
	return b


static func _label(text: String, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
