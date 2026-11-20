class_name LookLabel
extends Node3D
## Labels on look (VR: VrRig `label`; flat: main.gd with a desktop eye tracker): what the tracked eyes rest on (a
## creature, furniture, items on the ground, a vehicle part, a wall or door) gets one line with its name and a short
## second line, floating over it, after DWELL_S on the same thing; it goes LINGER_S after the eyes leave. Only tracked
## eyes show it (the head's gaze never does: without an eye tracker nothing changes). Names come from the snapshot
## and id tables (LookRay); only shown, never logged. One world-space Label3D, the same in both modes.

const DWELL_S := 0.25
const LINGER_S := 0.3
const LOOK_S := 0.1             # the ray looks again at most this often
const MAX_M := 30.0             # labels only this far out
const OVER_M := 0.35            # the label this far over the point looked at
const MAX_COLS := 60
const COLOR := Color(0.95, 0.95, 0.9)

var enabled := true             # the feature's toggle (the Eye tracking settings group)
var text := ""                  # the label's text when shown (tests)
var _label: Label3D
var _key := ""                  # what the eyes rest on now ("" nothing)
var _since := 0.0               # how long they have rested on it
var _away := 0.0                # how long since they left what is shown
var _wait := 0.0
var _hit := {}                  # the last cast's result
var _pending := ""              # the text for _key, shown once DWELL_S passed


func _init() -> void:
	name = "LookLabel"
	top_level = true
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.pixel_size = 0.0007
	_label.font_size = 26
	_label.outline_size = 8
	_label.no_depth_test = true
	_label.modulate = COLOR
	add_child(_label)
	visible = false


## Per frame: `look` the gaze ({from, dir, eyes}; only `eyes` true counts), `can` false while a menu or panel is up.
func update(delta: float, world: WorldView, look: Dictionary, can: bool) -> void:
	if not enabled or not can or world == null or world.snapshot == null or not look.get("eyes", false) \
			or not look.get("from") is Vector3 or not look.get("dir") is Vector3 or not is_finite(delta) or delta < 0.0 			or not (look["from"] as Vector3).is_finite() or not (look["dir"] as Vector3).is_finite() 			or (look["dir"] as Vector3).length() < 0.5:
		clear()
		return
	_wait -= delta
	if _wait <= 0.0:
		_wait = LOOK_S
		var ray := LookRay.new(world)
		_hit = ray.cast(look["from"], look["dir"], MAX_M)
		var t := text_for(ray, _hit)
		var key := "" if t.is_empty() else "%s|%s" % [_hit["square"], t]
		if key != _key:
			_key = key
			_pending = t
			_since = 0.0
	_since += delta
	if _key != "" and _since >= DWELL_S:
		if text != _pending:
			text = _pending
			_label.text = text
		_away = 0.0
		visible = true
		global_position = (_hit["point"] as Vector3) + Vector3(0, OVER_M, 0)
	elif visible:
		_away += delta
		if _away >= LINGER_S:
			visible = false
			text = ""


## Hidden and forgotten.
func clear() -> void:
	visible = false
	text = ""
	_pending = ""
	_key = ""
	_since = 0.0
	_away = 0.0
	_wait = 0.0
	_hit = {}


## The label for LookRay hit `r` ("" for none: nothing hit, or bare floor, ceiling or ground): a name line and a short
## line, each at most MAX_COLS.
static func text_for(ray: LookRay, r: Dictionary) -> String:
	if not r.get("hit", false) or not r.get("square") is Vector3i:
		return ""
	var sq: Vector3i = r["square"]
	var what := str(r.get("what", ""))
	var lines := ray.describe(sq)
	var name := what
	var short := ""
	var snap := ray.world.snapshot
	var cr := snap.creature_at(sq) if snap != null else null
	if cr != null and what == ray.creature_name(cr):
		short = "health %d%%" % roundi(cr.hp_frac * 100.0 / 255.0)
	elif r.has("vehicle"):
		short = "vehicle"
	elif what == "furniture":
		name = _after(lines, "furniture: ")
		short = "furniture"
	elif what in ["floor", "ceiling"]:
		var items := _after(lines, "items ")
		if items.is_empty() or what == "ceiling":
			return ""
		name = items.substr(items.find(":") + 1).strip_edges() if items.contains(":") else items
		short = "on the ground"
	else:
		name = _after(lines, "terrain: ")
		short = what
	if name.is_empty():
		name = what
	return "%s\n%s" % [name.left(MAX_COLS), short.left(MAX_COLS)]


## The rest of the first line starting with `head`, "" when none.
static func _after(lines: PackedStringArray, head: String) -> String:
	for l in lines:
		if l.begins_with(head):
			return l.substr(head.length())
	return ""
