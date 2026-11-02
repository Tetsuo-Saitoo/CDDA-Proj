class_name TerrainCatalog
extends RefCounted
## Decides how each terrain id is built: its registry entry (assets/registry, `kind: terrain`) first,
## then rules on the id name, then a coloured box keyed by the name, so nothing is invisible.
## Until block B6 sends terrain flags (WALL, DOOR, connect_groups, ...) the name rules stand in for them.
##
## Registry files are hostile input too (mods will ship them): file count, depth, sizes, types and
## string lengths are capped; bad files and entries are skipped and listed in [member warnings].

enum Kind { NONE, FLOOR, WALL, WINDOW, DOOR, FENCE, STAIRS_UP, STAIRS_DOWN, LADDER_UP, LADDER_DOWN,
		RAMP_UP, ROOF, WATER, TREE, TREETOP, SHRUB, BOX }

const MAX_FILE_BYTES := 4 << 20
const MAX_FILES := 256
const MAX_DEPTH := 4
const MAX_ENTRIES := 100000
const MAX_IDS_PER_ENTRY := 256
const MAX_STR := 128

const MESHERS := {
	"floor": Kind.FLOOR, "wall": Kind.WALL, "window": Kind.WINDOW, "door": Kind.DOOR,
	"fence": Kind.FENCE, "stairs_up": Kind.STAIRS_UP, "stairs_down": Kind.STAIRS_DOWN,
	"ramp": Kind.RAMP_UP, "water": Kind.WATER, "roof": Kind.ROOF, "open_air": Kind.NONE,
}

## Placeholder colours for registry materials until assets/materials exists.
const MATERIAL_COLORS := {
	"soil": Color(0.42, 0.32, 0.22), "grass": Color(0.33, 0.52, 0.22),
	"asphalt": Color(0.2, 0.2, 0.22), "concrete": Color(0.58, 0.58, 0.56),
	"wood_floor": Color(0.6, 0.45, 0.28), "plaster_white": Color(0.88, 0.86, 0.82),
	"brick": Color(0.58, 0.27, 0.2), "roof_tar": Color(0.24, 0.23, 0.25),
}

const COLOR_WORDS := {
	"white": Color(0.9, 0.89, 0.86), "gray": Color(0.55, 0.55, 0.56), "grey": Color(0.55, 0.55, 0.56),
	"black": Color(0.15, 0.15, 0.16), "red": Color(0.65, 0.2, 0.18), "green": Color(0.3, 0.55, 0.3),
	"blue": Color(0.3, 0.4, 0.7), "yellow": Color(0.85, 0.75, 0.3), "orange": Color(0.85, 0.5, 0.2),
	"purple": Color(0.5, 0.3, 0.6), "pink": Color(0.85, 0.55, 0.65), "brown": Color(0.45, 0.32, 0.2),
}
## CDDA's one-letter wall colour suffixes (t_wall_w, t_wall_b, t_wall_P, ...).
const WALL_LETTERS := {
	"w": "white", "b": "blue", "g": "green", "r": "red", "y": "yellow", "P": "pink", "p": "purple",
}

## Checked before every other rule: things that only look like floors or water by name.
const BOX_WORDS := ["pump", "control", "pipe", "mound", "sandbox", "slide", "monkey_bars", "console"]
const FLOOR_WORDS := ["floor", "carpet", "linoleum", "grass", "dirt", "moss", "pavement", "sidewalk",
		"concrete", "sand", "gravel", "clay", "mud", "road", "bridge", "grate", "manhole", "tile",
		"rug", "ground", "parquet", "slab", "thconc", "ramp_down", "rock_floor"]

const GROUND := Color(0.38, 0.34, 0.26)
const UNKNOWN := Color(1.0, 0.0, 1.0)


class Style:
	var kind := 0
	var color := Color.MAGENTA
	var color2 := Color.MAGENTA   # tree crowns
	var state := 0                # door: 0 closed, 1 open, 2 empty; window: 0 glass, 1 open, 2 curtains, 3 glass wall
	var height := 3.0
	var glass := false            # glass door leaf


var warnings := PackedStringArray()
var _registry := {}   # id name -> {"mesher": String, "material": String}
var _names := {}      # int id -> name
var _styles := {}     # int id -> Style
var _entries := 0


## The snapshot's id -> name table. Clears cached styles.
func set_names(names: Dictionary) -> void:
	_names = names
	_styles.clear()


func style_for(id: int) -> Style:
	var s: Style = _styles.get(id)
	if s == null:
		s = make_style(_names.get(id, ""))
		_styles[id] = s
	return s


func make_style(name: String) -> Style:
	var s := Style.new()
	if name.is_empty():
		s.kind = Kind.BOX
		s.color = UNKNOWN
		s.height = 1.0
		return s
	var reg: Dictionary = _registry.get(name, {})
	var mesher: String = reg.get("mesher", "")
	s.kind = MESHERS[mesher] if MESHERS.has(mesher) else kind_from_name(name)
	_dress(name, s)
	var material: String = reg.get("material", "")
	if MATERIAL_COLORS.has(material):
		s.color = MATERIAL_COLORS[material]
	return s


static func kind_from_name(n: String) -> int:
	if n == "t_null" or n.contains("open_air"):
		return Kind.NONE
	for w: String in BOX_WORDS:
		if n.contains(w):
			return Kind.BOX
	if n.contains("stairs_up"):
		return Kind.STAIRS_UP
	if n.contains("stairs_down"):
		return Kind.STAIRS_DOWN
	if n.contains("ladder_up"):
		return Kind.LADDER_UP
	if n.contains("ladder_down"):
		return Kind.LADDER_DOWN
	if n.contains("ramp_up"):
		return Kind.RAMP_UP
	if n.contains("door"):
		return Kind.DOOR
	if n.contains("window") or n.contains("curtains") or n.contains("wall_glass"):
		return Kind.WINDOW
	if n.contains("roof") and not n.contains("no_roof"):
		return Kind.ROOF
	if n.contains("treetop"):
		return Kind.TREETOP
	if n.begins_with("t_tree") or n == "t_trunk":
		return Kind.TREE
	if n.contains("shrub") or n.contains("underbrush") or n.contains("fern") or n.contains("hedge"):
		return Kind.SHRUB
	if n.contains("fence") or n.contains("railing") or n.contains("gutter") or n.contains("gate"):
		return Kind.FENCE
	if n.contains("wall") or n == "t_soil" or n == "t_rock":
		return Kind.WALL
	if n.contains("water") or n.contains("sewage") or n.contains("puddle"):
		return Kind.WATER
	for w: String in FLOOR_WORDS:
		if n.contains(w):
			return Kind.FLOOR
	return Kind.BOX


## Colour, state and height from the name, per kind.
static func _dress(n: String, s: Style) -> void:
	var tokens := n.split("_")
	var word := _color_word(tokens)
	match s.kind:
		Kind.FLOOR:
			s.color = word if word.a > 0.0 else _floor_color(n)
		Kind.WALL:
			if word.a == 0.0 and WALL_LETTERS.has(tokens[tokens.size() - 1]):
				word = COLOR_WORDS[WALL_LETTERS[tokens[tokens.size() - 1]]]
			s.color = word if word.a > 0.0 else _wall_color(n)
			s.height = 1.2 if n.contains("half") else CddaCoords.LEVEL_M
		Kind.DOOR:
			s.glass = n.contains("glass")
			s.color = word if word.a > 0.0 else (Color(0.5, 0.52, 0.55) if n.contains("metal") else Color(0.48, 0.32, 0.18))
			if tokens.has("o") or n.contains("open"):
				s.state = 1
			elif tokens.has("b") or n.contains("frame") or n.contains("empty") or n.contains("broken"):
				s.state = 2
		Kind.WINDOW:
			s.color = Color(0.8, 0.78, 0.74)
			if n.contains("wall_glass"):
				s.state = 3
			elif n.contains("curtains"):
				s.state = 2
				s.color2 = Color(0.35, 0.3, 0.4)
			elif n.contains("open") or n.contains("empty") or n.contains("frame") or n.contains("broken") or tokens.has("b"):
				s.state = 1
		Kind.FENCE:
			var metal := n.contains("chain") or n.contains("wire") or n.contains("metal") or n.contains("railing") or n.contains("gutter")
			s.color = Color(0.6, 0.62, 0.64) if metal else Color(0.5, 0.36, 0.22)
			s.height = 0.3 if n.contains("gutter") else (2.0 if n.contains("chain") else 1.1)
		Kind.ROOF:
			s.color = word if word.a > 0.0 else (Color(0.3, 0.38, 0.6) if n.contains("canvas") else Color(0.32, 0.3, 0.3))
		Kind.WATER:
			s.color = Color(0.35, 0.38, 0.25) if n.contains("sewage") else Color(0.2, 0.35, 0.55)
		Kind.TREE, Kind.TREETOP:
			s.color = Color(0.36, 0.26, 0.17)
			if n.contains("dead"):
				s.color2 = Color(0.42, 0.38, 0.3)
			elif n.contains("pine") or n.contains("evergreen") or n.contains("juniper"):
				s.color2 = Color(0.12, 0.3, 0.16)
			else:
				s.color2 = Color(0.22, 0.45, 0.18)
		Kind.SHRUB:
			s.color = Color(0.25, 0.42, 0.2)
			s.height = 0.8
		Kind.STAIRS_UP, Kind.LADDER_UP:
			s.color = Color(0.55, 0.42, 0.28) if n.contains("wood") or n.contains("ladder") else Color(0.55, 0.55, 0.53)
		Kind.RAMP_UP:
			s.color = Color(0.45, 0.35, 0.24) if n.contains("earth") else Color(0.55, 0.55, 0.53)
		Kind.BOX:
			s.color = _hash_color(n)
			s.height = 1.0


static func _color_word(tokens: PackedStringArray) -> Color:
	for t in tokens:
		if COLOR_WORDS.has(t):
			return COLOR_WORDS[t]
	return Color(0, 0, 0, 0)


static func _floor_color(n: String) -> Color:
	if n.contains("grass"):
		return Color(0.55, 0.5, 0.28) if n.contains("dead") else Color(0.33, 0.52, 0.22)
	if n.contains("moss") or n.contains("forest"):
		return Color(0.28, 0.36, 0.18)
	if n.contains("dirt") or n.contains("soil") or n.contains("mud") or n.contains("ramp"):
		return Color(0.42, 0.32, 0.22)
	if n.contains("sand"):
		return Color(0.8, 0.72, 0.5)
	if n.contains("pavement") or n.contains("road"):
		return Color(0.2, 0.2, 0.22)
	if n.contains("sidewalk") or n.contains("concrete") or n.contains("thconc") or n.contains("bridge"):
		return Color(0.58, 0.58, 0.56)
	if n.contains("linoleum"):
		return Color(0.82, 0.82, 0.8)
	if n.contains("grate") or n.contains("manhole"):
		return Color(0.3, 0.3, 0.32)
	if n == "t_floor" or n.contains("wood") or n.contains("waxed") or n.contains("parquet"):
		return Color(0.6, 0.45, 0.28)
	return _hash_color(n)


static func _wall_color(n: String) -> Color:
	if n.contains("brick"):
		return Color(0.58, 0.27, 0.2)
	if n.contains("conc"):
		return Color(0.58, 0.58, 0.56)
	if n.contains("rock") or n.contains("stone"):
		return Color(0.45, 0.43, 0.4)
	if n.contains("soil") or n.contains("dirt") or n.contains("earth"):
		return Color(0.42, 0.32, 0.22)
	if n.contains("wood") or n.contains("log"):
		return Color(0.5, 0.36, 0.22)
	if n.contains("metal"):
		return Color(0.5, 0.52, 0.55)
	return Color(0.85, 0.83, 0.79)


## Stable placeholder colour per id name.
static func _hash_color(n: String) -> Color:
	return Color.from_hsv(float(posmod(n.hash(), 360)) / 360.0, 0.5, 0.75)


## Loads every *.json under dir (depth and count capped). Missing dir: a warning, no entries.
func load_registry_dir(dir_path: String) -> void:
	var files := PackedStringArray()
	_collect(dir_path, 0, files)
	for f in files:
		_load_registry_file(f)
	_styles.clear()


func _collect(dir_path: String, depth: int, out: PackedStringArray) -> void:
	if depth > MAX_DEPTH:
		return
	var da := DirAccess.open(dir_path)
	if da == null:
		warnings.append("registry: cannot open %s" % dir_path)
		return
	var names := da.get_files()
	names.sort()
	for name in names:
		if name.ends_with(".json"):
			if out.size() >= MAX_FILES:
				warnings.append("registry: more than %d files, rest skipped" % MAX_FILES)
				return
			out.append(dir_path.path_join(name))
	var dirs := da.get_directories()
	dirs.sort()
	for sub in dirs:
		_collect(dir_path.path_join(sub), depth + 1, out)


func _load_registry_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		warnings.append("registry: cannot open %s" % path)
		return
	if f.get_length() > MAX_FILE_BYTES:
		warnings.append("registry: %s is larger than %d bytes, skipped" % [path, MAX_FILE_BYTES])
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK or not json.data is Array:
		warnings.append("registry: %s is not a JSON list, skipped" % path)
		return
	for e: Variant in json.data:
		_entries += 1
		if _entries > MAX_ENTRIES:
			warnings.append("registry: more than %d entries, rest skipped" % MAX_ENTRIES)
			return
		if not e is Dictionary:
			continue
		var d: Dictionary = e
		if _str(d.get("type")) != "fp3d_model" or _str(d.get("kind")) != "terrain":
			continue
		var mesher := _str(d.get("mesher"))
		var material := _str(d.get("material"))
		if (not mesher.is_empty() and not MESHERS.has(mesher)) or material.length() > MAX_STR:
			warnings.append("registry: %s: bad mesher or material, entry skipped" % path)
			continue
		var ids: Variant = d.get("id")
		var list: Array = [ids] if ids is String else (ids if ids is Array else [])
		if list.is_empty() or list.size() > MAX_IDS_PER_ENTRY:
			warnings.append("registry: %s: bad id list, entry skipped" % path)
			continue
		for id: Variant in list:
			if id is String and (id as String).length() <= MAX_STR:
				_registry[id] = {"mesher": mesher, "material": material}


static func _str(v: Variant) -> String:
	return v if v is String else ""
