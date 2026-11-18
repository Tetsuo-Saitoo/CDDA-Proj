class_name GunMods
extends RefCounted
## Gun modification by hand (TASKS "Gun modification by hand", slice S1): where CDDA's gunmod locations sit on the
## WeaponViewmodel gun shapes, and plain boxes for the mods installed there (real models later). CDDA decides which
## mods fit and where (Snapshot.player_gun `mods`, the id tables' `mod_locations`); this only places them.
## - slot(shape, location, k): the k-th mod at that location, {at (model space), size}. Mount and accessory locations
##   sit by the part they mount on (ALIAS), smaller; a location this doesn't know sits on the side (OTHER).
## - mods_of(gun): player_gun's `mods` checked again: bad entries dropped, at most MAX_MODS.
## - dress(model, shape, mods): the boxes under the model's HOLDER node, one "Mod<i>" per mod (meta uid, type,
##   location), replacing what was there.

const MAX_MODS := 16              # mods shown on one gun (the snapshot's cap)
const MAX_LOC := IdTables.MAX_MOD_LOCATION   # a location id's length (bytes)
const MAX_UID := 1 << 53
const HOLDER := "Mods"
const COLOR := Color(0.3, 0.32, 0.35)   # a bit lighter than the gun's metal, so a mod reads as added
const STEP := 1.15                # the next mod at one location sits this many of its sizes along the slot's `along`
const MAX_STACK := 3              # ... at most this many steps
const OTHER := ["mechanism", Vector3(0.0, -0.02, 0.0), 0.8]   # a location not listed here: by the mechanism

## shape -> location -> [at, size, along] in the model's space (WeaponViewmodel.build's parts, -z the bore).
const SLOTS := {
	"pistol": {
		"sights": [Vector3(0.0, 0.034, -0.04), Vector3(0.022, 0.022, 0.045), Vector3(0, 0, -1)],
		"muzzle": [Vector3(0.0, 0.0, -0.215), Vector3(0.032, 0.032, 0.11), Vector3(0, 0, -1)],
		"barrel": [Vector3(0.0, 0.0, -0.175), Vector3(0.026, 0.026, 0.03), Vector3(0, 0, -1)],
		"bore": [Vector3(0.0, 0.0, -0.158), Vector3(0.012, 0.012, 0.01), Vector3(0, 0, -1)],
		"underbarrel": [Vector3(0.0, -0.035, -0.11), Vector3(0.026, 0.022, 0.05), Vector3(0, 0, 1)],
		"rail": [Vector3(0.024, -0.005, -0.1), Vector3(0.012, 0.018, 0.04), Vector3(0, 0, 1)],
		"stock": [Vector3(0.0, -0.04, 0.11), Vector3(0.02, 0.05, 0.14), Vector3(0, -1, 0)],
		"mechanism": [Vector3(-0.022, 0.0, -0.02), Vector3(0.008, 0.02, 0.03), Vector3(0, 0, -1)],
	},
	"long": {
		"sights": [Vector3(0.0, 0.05, -0.1), Vector3(0.03, 0.035, 0.14), Vector3(0, 0, -1)],
		"muzzle": [Vector3(0.0, 0.012, -0.68), Vector3(0.036, 0.036, 0.12), Vector3(0, 0, -1)],
		"barrel": [Vector3(0.0, 0.012, -0.45), Vector3(0.032, 0.032, 0.2), Vector3(0, 0, -1)],
		"bore": [Vector3(0.0, 0.012, -0.617), Vector3(0.014, 0.014, 0.01), Vector3(0, 0, -1)],
		"underbarrel": [Vector3(0.0, -0.035, -0.36), Vector3(0.03, 0.04, 0.12), Vector3(0, 0, -1)],
		"rail": [Vector3(0.03, 0.012, -0.32), Vector3(0.016, 0.022, 0.06), Vector3(0, 0, -1)],
		"stock": [Vector3(0.0, -0.03, 0.18), Vector3(0.042, 0.09, 0.24), Vector3(0, -1, 0)],
		"mechanism": [Vector3(-0.026, 0.0, -0.08), Vector3(0.01, 0.03, 0.06), Vector3(0, 0, -1)],
	},
	"launcher": {
		"sights": [Vector3(0.0, 0.085, -0.12), Vector3(0.03, 0.03, 0.08), Vector3(0, 0, -1)],
		"muzzle": [Vector3(0.0, 0.02, -0.49), Vector3(0.11, 0.11, 0.08), Vector3(0, 0, -1)],
		"barrel": [Vector3(0.0, 0.02, -0.38), Vector3(0.11, 0.11, 0.06), Vector3(0, 0, -1)],
		"bore": [Vector3(0.0, 0.02, -0.44), Vector3(0.02, 0.02, 0.01), Vector3(0, 0, -1)],
		"underbarrel": [Vector3(0.0, -0.05, -0.3), Vector3(0.03, 0.04, 0.1), Vector3(0, 0, -1)],
		"rail": [Vector3(0.06, 0.02, -0.25), Vector3(0.016, 0.022, 0.06), Vector3(0, 0, -1)],
		"stock": [Vector3(0.0, -0.02, 0.24), Vector3(0.04, 0.08, 0.18), Vector3(0, -1, 0)],
		"mechanism": [Vector3(-0.055, 0.02, -0.05), Vector3(0.01, 0.03, 0.06), Vector3(0, 0, -1)],
	},
}

## CDDA's other locations -> [the slot they sit by, offset from it, size scale].
const ALIAS := {
	"sights mount": ["sights", Vector3(0.0, -0.014, 0.0), 0.7],
	"lens": ["sights", Vector3(0.0, 0.0, -0.03), 0.6],
	"arrow rest": ["sights", Vector3(0.0, -0.02, 0.0), 0.6],
	"rail mount": ["rail", Vector3(0.0, -0.012, 0.0), 0.7],
	"underbarrel mount": ["underbarrel", Vector3(0.0, 0.012, 0.0), 0.7],
	"stock mount": ["stock", Vector3(0.0, 0.0, -0.06), 0.6],
	"stock accessory": ["stock", Vector3(0.026, 0.0, 0.0), 0.6],
	"sling": ["stock", Vector3(0.0, -0.045, 0.0), 0.5],
	"brass catcher": ["mechanism", Vector3(-0.015, 0.0, 0.0), 0.8],
	"stabilizer": ["barrel", Vector3(0.0, -0.02, 0.0), 0.7],
	"dampening": ["barrel", Vector3.ZERO, 1.1],
	"emitter": ["muzzle", Vector3.ZERO, 0.9],
}


## A CDDA gunmod location id as the bridge may send it (IdTables.is_location: letters, digits, space, _ and -, 1..MAX_LOC
## bytes).
static func valid_location(v: Variant) -> bool:
	return IdTables.is_location(v)


## Where the k-th mod at `location` sits on a gun of `shape`: {at, size} in the model's space; {} for a shape with no
## slots (bow, melee, ...).
static func slot(shape: String, location: String, k := 0) -> Dictionary:
	var slots: Dictionary = SLOTS.get(shape, {})
	if slots.is_empty():
		return {}
	var base := location
	var off := Vector3.ZERO
	var scale := 1.0
	if not slots.has(base):
		var a: Array = ALIAS.get(location, OTHER)
		base = a[0]
		off = a[1]
		scale = a[2]
	var s: Array = slots[base]
	var size: Vector3 = s[1] * scale
	var along: Vector3 = s[2]
	var steps := clampi(k, 0, MAX_STACK)
	return {"at": s[0] + off + along * (absf(along.dot(size)) * STEP * steps), "size": size}


## Snapshot.player_gun's `mods` checked again ([{uid, type, location, flags}]): entries that aren't whole are
## dropped, at most MAX_MODS kept.
static func mods_of(gun: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var v: Variant = (gun as Dictionary).get("mods") if gun is Dictionary else null
	if not v is Array:
		return out
	for e: Variant in (v as Array).slice(0, MAX_MODS):
		if not e is Dictionary:
			continue
		var d: Dictionary = e
		var uid := _whole(d.get("uid"), 1, MAX_UID - 1)
		var t := _whole(d.get("type"), 1, Snapshot.MAX_ID)
		var loc: Variant = d.get("location")
		if uid < 0 or t < 0 or not valid_location(loc):
			continue
		out.append({"uid": uid, "type": t, "location": loc, "flags": maxi(_whole(d.get("flags", 0), 0, 255), 0)})
	return out


## The mods' boxes on `model` (a WeaponViewmodel.build model of `shape`) under its HOLDER node, replacing the old
## ones; none for a shape with no slots. Returns the holder (null when there is none).
static func dress(model: Node3D, shape: String, mods: Array[Dictionary]) -> Node3D:
	if model == null:
		return null
	var old := model.get_node_or_null(HOLDER)
	if old != null:
		model.remove_child(old)
		old.free()
	if mods.is_empty() or not SLOTS.has(shape):
		return null
	var holder := Node3D.new()
	holder.name = HOLDER
	model.add_child(holder)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = COLOR
	mat.roughness = 0.5
	var at_loc := {}
	for i in mods.size():
		var m: Dictionary = mods[i]
		var loc: String = m["location"]
		var k: int = at_loc.get(loc, 0)
		at_loc[loc] = k + 1
		var s := slot(shape, loc, k)
		var b := BoxMesh.new()
		b.size = s["size"]
		b.material = mat
		var mi := MeshInstance3D.new()
		mi.name = "Mod%d" % i
		mi.mesh = b
		mi.position = s["at"]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("uid", m["uid"])
		mi.set_meta("type", m["type"])
		mi.set_meta("location", loc)
		holder.add_child(mi)
	return holder


## A whole number in lo..hi (an int, or a float with nothing after the point), else -1.
static func _whole(v: Variant, lo: int, hi: int) -> int:
	var n := 0
	if v is int:
		n = v
	elif v is float and is_finite(v) and v == floorf(v) and absf(v) < 9.0e15:
		n = int(v)
	else:
		return -1
	return n if n >= lo and n <= hi else -1
