class_name ModelLibrary
extends RefCounted
## Loads the `.glb` models of the asset registry (docs/MODELS.md) at run time with GLTFDocument and reads
## their named points (markers). Run time, not Godot's importer (ResourceLoader): models live outside the
## Godot project (assets/models; mods will ship their own), which an exported game's importer never sees,
## and reading the bytes ourselves lets us check them before Godot parses them.
##
## Model files are hostile input like the registry: the path must stay under [member root]; file size,
## JSON size, node, mesh, accessor, material, image and animation counts, image sizes, triangles and
## markers are capped; the glTF JSON is checked first (no external files, no node cycles, embedded PNG or
## JPEG only). A bad file is skipped with a warning and the caller falls back (placeholder, then the rest
## of the registry chain). Results, failures too, are cached per path.
##
## Models face +Z (Godot's model front), origin at the bottom centre, 1 unit = 1 m.
##
## A registry entry with a `material` gets a tinted variant ([method get_tinted]): copies of the model's
## meshes and materials with the albedo blended toward the palette material's colour, so a model made in
## neutral light grey can serve several ids. One variant per path and palette material, cached.

const MAX_FILE_BYTES := 32 << 20
const MAX_JSON_BYTES := 4 << 20
const MAX_PATH := 200
const MAX_NODES := 512
const MAX_DEPTH := 32
const MAX_MESHES := 256
const MAX_PRIMITIVES := 512
const MAX_ACCESSORS := 4096
const MAX_ACCESSOR_COUNT := 1 << 20
const MAX_MATERIALS := 32
const MAX_TEXTURES := 32
const MAX_IMAGES := 16
const MAX_IMAGE_SIDE := 4096
const MAX_ANIMATIONS := 64
const MAX_SKINS := 8
const MAX_MORPH_TARGETS := 8
## MODELS.md budgets go up to 15,000 triangles; this leaves room without letting a file stall the game.
const MAX_TRIANGLES := 60000
const MAX_MARKERS := 128
const MAX_MODELS := 1024
## Tinted variants copy their model's meshes: past this many, models are drawn untinted.
const MAX_TINTED := 512
const MAX_NAME := 128
const MAX_NUMBER := 99
const MAX_WARNINGS := 256
const EXTENSIONS_OK := ["KHR_texture_transform", "KHR_materials_unlit", "KHR_materials_emissive_strength",
		"KHR_mesh_quantization"]

## Point markers: only a transform (a mesh with that name is hidden).
const POINTS := ["grip", "grip_2", "muzzle", "mag_well", "sight", "opening", "spout", "contents", "rack",
		"spit", "fire", "light"]
const NUMBERED_POINTS := ["burner"]
## Moving parts: drawn; their transform and part index are kept for animating them later.
const PARTS := ["lid"]
const NUMBERED_PARTS := ["door", "drawer", "handle", "knob"]
const COLLIDER_SUFFIX := "-convcolonly"
## Share of a registry material's colour in a tinted model's albedo (the rest keeps the model's own colour
## and texture detail): albedo colour * lerp(white, material colour, TINT).
const TINT := 0.7

enum Marker { NONE, POINT, PART, SURFACE, FILL, COLLIDER }


class Model:
	var path := ""
	## Drawn meshes: [Mesh, Transform3D in model space].
	var parts: Array = []
	## Marker name -> Transform3D in model space (points, parts, surface_N, fill).
	var markers := {}
	## Moving-part marker name (lid, door_N, drawer_N, handle_N, knob_N) -> index into parts.
	var marker_parts := {}
	## Item surfaces in order of N: [Transform3D, Rect2 (x/z extent in the plane's own space), plane y].
	var surfaces: Array = []
	## The fill volume (hidden): [Mesh, Transform3D], empty without one.
	var fill: Array = []
	## Convex colliders from `<name>-convcolonly` meshes (hidden): [Shape3D, Transform3D].
	var colliders: Array = []
	var aabb := AABB()
	var triangles := 0
	## Registry material this variant is tinted with ("" = the model as made).
	var tint := ""

	func has_marker(name: String) -> bool:
		return markers.has(name)

	func marker(name: String) -> Transform3D:
		return markers.get(name, Transform3D.IDENTITY)

	## Names of the numbered markers with this prefix (door, drawer, handle, surface, burner, knob), in order.
	func numbered(prefix: String) -> PackedStringArray:
		var out := PackedStringArray()
		for n in range(1, MAX_NUMBER + 1):
			if markers.has("%s_%d" % [prefix, n]):
				out.append("%s_%d" % [prefix, n])
		return out


## Folder the registry's `model` paths are relative to (assets/models).
var root := ""
var warnings := PackedStringArray()
## Caps (tests lower them).
var max_file_bytes := MAX_FILE_BYTES
var max_nodes := MAX_NODES
var max_triangles := MAX_TRIANGLES
var max_markers := MAX_MARKERS
var max_tinted := MAX_TINTED
var _cache := {}   # relative path -> Model, or null when it failed
var _tinted := {}  # "path|material" -> tinted Model (at most MAX_TINTED)
var _full_warned := false
var _tint_warned := false


## The model at a registry path, or null (missing, outside the folder, or a bad file: see warnings).
func get_model(rel: String) -> Model:
	if _cache.has(rel):
		return _cache[rel]
	if _cache.size() >= MAX_MODELS:
		if not _full_warned:
			_warn("more than %d models, the rest aren't loaded" % MAX_MODELS)
			_full_warned = true
		return null
	var m := _load(rel)
	_cache[rel] = m
	return m


## The model at a registry path tinted toward a palette material (CddaPalette.MATERIALS), cached: the same
## object for the same path and material. A name that isn't a palette material ("" included) gives the
## model as made, and so does any new variant past MAX_TINTED (with a warning); null when the model
## doesn't load.
func get_tinted(rel: String, material: String) -> Model:
	var m := get_model(rel)
	if m == null or not CddaPalette.MATERIALS.has(material):
		return m
	var key := rel + "|" + material
	var t: Model = _tinted.get(key)
	if t == null:
		if _tinted.size() >= max_tinted:
			if not _tint_warned:
				_warn("more than %d tinted models, the rest are drawn untinted" % max_tinted)
				_tint_warned = true
			return m
		t = tinted(m, CddaPalette.material(material))
		t.tint = material
		_tinted[key] = t
	return t


## A variant of m whose drawn meshes use copies of its materials, the albedo colour multiplied by
## lerp(white, tint, TINT) (textures keep their detail). Meshes and materials shared inside the model stay
## shared in the variant; markers, surfaces, fill and colliders are m's own. m is left as it is.
static func tinted(m: Model, tint: Color) -> Model:
	var t := Model.new()
	t.path = m.path
	t.markers = m.markers
	t.marker_parts = m.marker_parts
	t.surfaces = m.surfaces
	t.fill = m.fill
	t.colliders = m.colliders
	t.aabb = m.aabb
	t.triangles = m.triangles
	var factor := Color.WHITE.lerp(Color(tint, 1.0), TINT)
	var meshes := {}      # original mesh -> its tinted copy
	var materials := {}   # original material -> its tinted copy
	var plain: Array = [null]   # tinted stand-in for surfaces without a material (made once)
	for p: Array in m.parts:
		var mesh: Mesh = p[0]
		if not meshes.has(mesh):
			meshes[mesh] = _tinted_mesh(mesh, factor, materials, plain)
		t.parts.append([meshes[mesh], p[1]])
	return t


static func _tinted_mesh(mesh: Mesh, factor: Color, materials: Dictionary, plain: Array) -> Mesh:
	if not mesh is ArrayMesh:
		return mesh   # glTF meshes are ArrayMeshes; anything else is drawn as made
	var copy := mesh.duplicate() as ArrayMesh
	for s in copy.get_surface_count():
		var mat := copy.surface_get_material(s)
		if mat == null:
			if plain[0] == null:
				var sm := StandardMaterial3D.new()
				sm.albedo_color = factor
				plain[0] = sm
			copy.surface_set_material(s, plain[0])
		elif mat is BaseMaterial3D:
			if not materials.has(mat):
				var tm := mat.duplicate() as BaseMaterial3D
				tm.albedo_color = (mat as BaseMaterial3D).albedo_color * factor
				materials[mat] = tm
			copy.surface_set_material(s, materials[mat])
	return copy


## Absolute path of a registry path, or "" when it isn't a plain relative path inside root.
func resolve(rel: String) -> String:
	if root.is_empty() or rel.length() > MAX_PATH or not rel.ends_with(".glb") or rel.begins_with("/"):
		return ""
	for c in rel:
		if not ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c in "_-./"):
			return ""
	for seg in rel.split("/"):
		if seg.is_empty() or seg == "." or seg == "..":
			return ""
	var base := root.simplify_path()
	var full := base.path_join(rel).simplify_path()
	return full if full.begins_with(base + "/") else ""


func _load(rel: String) -> Model:
	var full := resolve(rel)
	if full.is_empty():
		_warn("%s: not a .glb path inside the models folder" % rel.left(80))
		return null
	if not FileAccess.file_exists(full):
		_warn("%s: missing" % rel)
		return null
	var f := FileAccess.open(full, FileAccess.READ)
	if f == null:
		_warn("%s: cannot open" % rel)
		return null
	if f.get_length() > max_file_bytes:
		_warn("%s: larger than %d bytes" % [rel, max_file_bytes])
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var why := check_glb(bytes)
	if not why.is_empty():
		_warn("%s: %s" % [rel, why])
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	state.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED   # never writes files
	if doc.append_from_buffer(bytes, "", state) != OK:
		_warn("%s: Godot can't read this glTF" % rel)
		return null
	var scene := doc.generate_scene(state)
	if scene == null:
		_warn("%s: Godot can't build this glTF" % rel)
		return null
	var m := Model.new()
	m.path = rel
	why = _read(scene, m)
	scene.free()
	if not why.is_empty():
		_warn("%s: %s" % [rel, why])
		return null
	return m


## "" when the bytes are a .glb within the caps, else why not. Checks the container and the glTF JSON
## before Godot parses anything.
func check_glb(bytes: PackedByteArray) -> String:
	if bytes.size() < 20 or bytes.decode_u32(0) != 0x46546C67:
		return "not a .glb file"
	if bytes.decode_u32(4) != 2:
		return "not glTF 2"
	if bytes.decode_u32(8) != bytes.size():
		return "length field doesn't match the file"
	var jlen := bytes.decode_u32(12)
	if bytes.decode_u32(16) != 0x4E4F534A or jlen > MAX_JSON_BYTES or 20 + jlen > bytes.size():
		return "bad JSON chunk"
	var bin_at := 20 + jlen
	var bin_len := 0
	if bin_at + 8 <= bytes.size():
		bin_len = bytes.decode_u32(bin_at)
		if bytes.decode_u32(bin_at + 4) != 0x004E4942 or bin_at + 8 + bin_len > bytes.size():
			return "bad BIN chunk"
		bin_at += 8
	var json := JSON.new()
	if json.parse(bytes.slice(20, 20 + jlen).get_string_from_utf8()) != OK or not json.data is Dictionary:
		return "bad glTF JSON"
	return _check_json(json.data, bytes, bin_at, bin_len)


func _check_json(g: Dictionary, bytes: PackedByteArray, bin_at: int, bin_len: int) -> String:
	var limits := {"nodes": max_nodes, "meshes": MAX_MESHES, "accessors": MAX_ACCESSORS, "bufferViews": MAX_ACCESSORS,
			"buffers": 1, "materials": MAX_MATERIALS, "textures": MAX_TEXTURES, "samplers": MAX_TEXTURES,
			"images": MAX_IMAGES, "animations": MAX_ANIMATIONS, "skins": MAX_SKINS, "scenes": 8, "cameras": 8,
			"extensionsRequired": 16, "extensionsUsed": 32}
	for key: String in limits:
		if g.has(key) and not g[key] is Array:
			return "%s is not a list" % key
		if _list(g, key).size() > limits[key]:
			return "more than %d %s" % [limits[key], key]
	for e: Variant in _list(g, "extensionsRequired"):
		if not e in EXTENSIONS_OK:
			return "needs an unsupported extension"
	for b: Variant in _list(g, "buffers"):
		if not b is Dictionary or (b as Dictionary).has("uri") or _int(b.get("byteLength"), 0, bin_len) < 0:
			return "buffers must be the .glb's own"
	var views := _list(g, "bufferViews")
	for v: Variant in views:
		if not v is Dictionary or _int(v.get("buffer"), 0, 0) < 0:
			return "bad buffer view"
		var off := _int(v.get("byteOffset", 0), 0, bin_len)
		var n := _int(v.get("byteLength"), 0, bin_len)
		if off < 0 or n < 0 or off + n > bin_len:
			return "buffer view outside the file"
	for img: Variant in _list(g, "images"):
		if not img is Dictionary or (img as Dictionary).has("uri"):
			return "images must be embedded"
		var vi := _int(img.get("bufferView"), 0, views.size() - 1)
		if vi < 0:
			return "bad image"
		var view: Dictionary = views[vi]
		var side := _image_side(bytes, bin_at + _int(view.get("byteOffset", 0), 0, bin_len), _int(view.get("byteLength"), 0, bin_len))
		if side < 0:
			return "images must be PNG or JPEG"
		if side > MAX_IMAGE_SIDE:
			return "an image is larger than %d px" % MAX_IMAGE_SIDE
	var accessors := _list(g, "accessors")
	var counts := PackedInt32Array()
	for a: Variant in accessors:
		if not a is Dictionary:
			return "bad accessor"
		var n := _int(a.get("count"), 0, MAX_ACCESSOR_COUNT)
		if n < 0:
			return "an accessor has more than %d elements" % MAX_ACCESSOR_COUNT
		if a.has("sparse") and (not a["sparse"] is Dictionary or _int(a["sparse"].get("count"), 0, MAX_ACCESSOR_COUNT) < 0):
			return "bad sparse accessor"
		counts.append(n)
	var tris := PackedInt32Array()
	var primitives := 0
	for mesh: Variant in _list(g, "meshes"):
		if not mesh is Dictionary or not mesh.get("primitives") is Array:
			return "bad mesh"
		var t := 0
		for p: Variant in mesh["primitives"]:
			primitives += 1
			if primitives > MAX_PRIMITIVES:
				return "more than %d mesh primitives" % MAX_PRIMITIVES
			if not p is Dictionary or not p.get("attributes") is Dictionary:
				return "bad mesh primitive"
			if p.has("targets") and (not p["targets"] is Array or (p["targets"] as Array).size() > MAX_MORPH_TARGETS):
				return "more than %d morph targets" % MAX_MORPH_TARGETS
			var src: Variant = p.get("indices", p["attributes"].get("POSITION"))
			var ai := _int(src, 0, counts.size() - 1)
			if ai < 0:
				return "bad mesh primitive"
			var mode := _int(p.get("mode", 4), 0, 6)
			t += counts[ai] / 3 if mode == 4 else (maxi(counts[ai] - 2, 0) if mode >= 5 else 0)
		tris.append(t)
	return _check_nodes(_list(g, "nodes"), tris)


## Node tree: valid links, one parent each, no cycles, depth, markers and triangles over all mesh uses.
func _check_nodes(nodes: Array, tris: PackedInt32Array) -> String:
	var parent := PackedInt32Array()
	parent.resize(nodes.size())
	parent.fill(-1)
	var triangles := 0
	var markers := 0
	for i in nodes.size():
		var n: Variant = nodes[i]
		if not n is Dictionary:
			return "bad node"
		var name: Variant = n.get("name", "")
		if not name is String or (name as String).length() > MAX_NAME:
			return "bad node name"
		if marker_kind(name) != Marker.NONE:
			markers += 1
		if n.has("mesh"):
			var mi := _int(n["mesh"], 0, tris.size() - 1)
			if mi < 0:
				return "bad node mesh"
			triangles += tris[mi]
		if n.has("children") and not n["children"] is Array:
			return "bad node children"
		for c: Variant in n.get("children", []):
			var ci := _int(c, 0, nodes.size() - 1)
			if ci < 0 or ci == i or parent[ci] >= 0:
				return "bad node children"
			parent[ci] = i
	for i in nodes.size():
		var depth := 0
		var at := parent[i]
		while at >= 0:
			depth += 1
			if depth > MAX_DEPTH:
				return "nodes nested deeper than %d (or a cycle)" % MAX_DEPTH
			at = parent[at]
	if markers > max_markers:
		return "more than %d markers" % max_markers
	if triangles > max_triangles:
		return "%d triangles, more than %d" % [triangles, max_triangles]
	return ""


## Reads the built scene into m: drawn parts, markers, surfaces, fill, colliders. "" or why it failed.
func _read(scene: Node, m: Model) -> String:
	var stack: Array = [[scene, Transform3D.IDENTITY, false]]   # node, parent transform, hidden
	var surfaces := {}
	var visited := 0
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var n: Node = e[0]
		var xf: Transform3D = e[1]
		var hidden: bool = e[2]
		visited += 1
		if visited > max_nodes + 1:
			return "more than %d nodes" % max_nodes
		if n is Node3D:
			xf = xf * (n as Node3D).transform
		var name := String(n.name)
		var kind := marker_kind(name)
		var mesh: Mesh = (n as MeshInstance3D).mesh if n is MeshInstance3D else null
		if kind != Marker.NONE and kind != Marker.COLLIDER:
			m.markers[name] = xf
		match kind:
			Marker.SURFACE:
				hidden = true
				var rect := Rect2(-0.2, -0.2, 0.4, 0.4)
				var y := 0.0
				if mesh != null:
					var a := mesh.get_aabb()
					rect = Rect2(a.position.x, a.position.z, a.size.x, a.size.z)
					y = a.get_center().y
				surfaces[name.get_slice("_", 1).to_int()] = [xf, rect, y]
			Marker.FILL:
				hidden = true
				if mesh != null:
					m.fill = [mesh, xf]
			Marker.COLLIDER:
				hidden = true
				if mesh != null:
					m.colliders.append([mesh.create_convex_shape(true, false), xf])
		if mesh != null:
			m.triangles += _triangles(mesh)
			if not hidden and kind != Marker.POINT:
				if kind == Marker.PART:
					m.marker_parts[name] = m.parts.size()
				var box := xf * mesh.get_aabb()
				m.aabb = box if m.parts.is_empty() else m.aabb.merge(box)
				m.parts.append([mesh, xf])
		for c in n.get_children():
			stack.append([c, xf, hidden])
	if m.markers.size() + m.colliders.size() > max_markers:
		return "more than %d markers" % max_markers
	if m.triangles > max_triangles:
		return "%d triangles, more than %d" % [m.triangles, max_triangles]
	if m.parts.is_empty():
		return "no visible mesh"
	var keys := surfaces.keys()
	keys.sort()
	for k: int in keys:
		m.surfaces.append(surfaces[k])
	return ""


static func marker_kind(name: String) -> Marker:
	if name.ends_with(COLLIDER_SUFFIX):
		return Marker.COLLIDER
	if name in POINTS:
		return Marker.POINT
	if name in PARTS:
		return Marker.PART
	if name == "fill":
		return Marker.FILL
	var cut := name.rfind("_")
	if cut <= 0:
		return Marker.NONE
	var num := name.substr(cut + 1)
	var prefix := name.left(cut)
	if not num.is_valid_int() or num != str(num.to_int()) or num.to_int() < 1 or num.to_int() > MAX_NUMBER:
		return Marker.NONE
	if prefix == "surface":
		return Marker.SURFACE
	if prefix in NUMBERED_POINTS:
		return Marker.POINT
	if prefix in NUMBERED_PARTS:
		return Marker.PART
	return Marker.NONE


static func _triangles(mesh: Mesh) -> int:
	var t := 0
	for s in mesh.get_surface_count():
		if mesh is ArrayMesh:
			var am := mesh as ArrayMesh
			var n := am.surface_get_array_index_len(s)
			if n <= 0:
				n = am.surface_get_array_len(s)
			t += n / 3
		else:
			t += (mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return t


## Larger side of an embedded PNG or JPEG from its header, -1 when it is neither.
static func _image_side(bytes: PackedByteArray, at: int, n: int) -> int:
	if n < 24 or at < 0 or at + n > bytes.size():
		return -1
	if bytes.decode_u32(at) == 0x474E5089 and bytes.decode_u32(at + 4) == 0x0A1A0A0D:
		return maxi(_be(bytes, at + 16, 4), _be(bytes, at + 20, 4))
	if bytes[at] != 0xFF or bytes[at + 1] != 0xD8:
		return -1
	var i := at + 2
	var end := at + n
	while i + 9 <= end:
		if bytes[i] != 0xFF:
			return -1
		var mk := bytes[i + 1]
		if mk == 0xFF:
			i += 1
			continue
		if mk == 0x01 or (mk >= 0xD0 and mk <= 0xD7):
			i += 2
			continue
		if mk >= 0xC0 and mk <= 0xCF and mk != 0xC4 and mk != 0xC8 and mk != 0xCC:
			return maxi(_be(bytes, i + 5, 2), _be(bytes, i + 7, 2))
		i += 2 + _be(bytes, i + 2, 2)
	return -1


static func _be(bytes: PackedByteArray, at: int, n: int) -> int:
	var v := 0
	for k in n:
		v = (v << 8) | bytes[at + k]
	return v


static func _list(g: Dictionary, key: String) -> Array:
	var v: Variant = g.get(key, [])
	return v if v is Array else []


## A whole number in lo..hi from JSON (numbers come as floats), else -1.
static func _int(v: Variant, lo: int, hi: int) -> int:
	if not (v is float or v is int):
		return -1
	var f := float(v)
	if f != floorf(f) or f < lo or f > hi:
		return -1
	return int(f)


func _warn(msg: String) -> void:
	if warnings.size() < MAX_WARNINGS:
		warnings.append("model " + msg)
		push_warning("model " + msg)
