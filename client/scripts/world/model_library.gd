class_name ModelLibrary
extends RefCounted
## Loads the `.glb` models of the asset registry (docs/MODELS.md) at run time with GLTFDocument and reads
## their named points (markers). Run time, not Godot's importer (ResourceLoader): models live outside the
## Godot project (assets/models; mods will ship their own), which an exported game's importer never sees,
## and reading the bytes ourselves lets us check them before Godot parses them.
##
## Model files are hostile input like the registry: the path must stay under [member root] (no links or
## junctions on the way); file size, JSON size, node, mesh, primitive, vertex, accessor, material and
## image counts, image sizes and pixels, triangles, markers, drawn parts and the model's size are capped.
## The glTF JSON is checked first: no external files, triangle lists only, every index and byte range in
## range, no animations, skins, cameras or morph targets, known extensions only, embedded PNG or JPEG
## only. A bad file is skipped with a warning and the caller falls back (placeholder, then the rest of the
## registry chain). Loaded models and failures are cached per path (case-folded). get_model may run on
## the meshing worker and the main thread at once (a mutex guards the cache).
##
## Models face +Z (Godot's model front), origin at the bottom centre, 1 unit = 1 m.
##
## Doors, drawers and lids (lid, door_N, drawer_N) become movers (Model.movers, block L8): their hinge or slide,
## how far they open, their handle, their meshes and surface_N planes in their own space, checked and capped
## (MAX_MOVERS), plus `still`, the model without them. Furniture draws `still` and opens the movers
## (PropMesher, WorldView, Grabbable.part). The rules are in docs/MODELS.md.
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
const MAX_MESH_PRIMITIVES := 32     # per mesh: each is a draw call wherever the mesh is used
const MAX_DRAWN_SURFACES := 128     # primitives over every node that uses a mesh (draw calls per model)
const MAX_PRIMITIVE_VERTICES := 65536
const MAX_VERTICES := 250000
const MAX_ACCESSORS := 4096
const MAX_ACCESSOR_COUNT := 1 << 20
const MAX_MATERIALS := 32
const MAX_TEXTURES := 32
const MAX_IMAGES := 16
const MAX_IMAGE_SIDE := 4096
## Decoded pixels of all images of one model (two 2048 px textures).
const MAX_IMAGE_PIXELS := 2 * 2048 * 2048
## Decoded image bytes (4 per pixel) of all loaded models together.
const MAX_IMAGE_BYTES := 512 << 20
## MODELS.md budgets go up to 15,000 triangles; this leaves room without letting a file stall the game.
const MAX_TRIANGLES := 60000
const MAX_MARKERS := 128
## Drawn meshes per model (WorldView makes one MultiMesh per part per submap).
const MAX_PARTS := 32
## Largest side of a model's bounds, in metres.
const MAX_MODEL_SIZE := 20.0
## Points a collider hull is built from (subsampled when the mesh has more).
const MAX_HULL_POINTS := 256
const MAX_MODELS := 1024
## Tinted variants copy their model's meshes: past this many, models are drawn untinted.
const MAX_TINTED := 512
## Triangles of every loaded model and tinted copy together (a mesh memory budget).
const MAX_TOTAL_TRIANGLES := 6000000
const MAX_FAILED := 1024
const MAX_NAME := 128
const MAX_NUMBER := 99
const MAX_WARNINGS := 256
const MAX_WARNING_LEN := 300
const EXTENSIONS_OK := ["KHR_texture_transform", "KHR_materials_unlit", "KHR_materials_emissive_strength",
		"KHR_mesh_quantization", "GODOT_single_root"]
## Top-level lists that must be empty or absent.
const UNSUPPORTED := ["animations", "skins", "cameras"]
const COMPONENT_BYTES := {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
## Accessor type -> (columns, rows).
const TYPE_SHAPE := {"SCALAR": Vector2i(1, 1), "VEC2": Vector2i(1, 2), "VEC3": Vector2i(1, 3),
		"VEC4": Vector2i(1, 4), "MAT2": Vector2i(2, 2), "MAT3": Vector2i(3, 3), "MAT4": Vector2i(4, 4)}
const SAMPLER_VALUES := {"magFilter": [9728, 9729], "minFilter": [9728, 9729, 9984, 9985, 9986, 9987],
		"wrapS": [33071, 33648, 10497], "wrapT": [33071, 33648, 10497]}
## Node transform fields -> number count.
const NODE_TRS := {"matrix": 16, "translation": 3, "rotation": 4, "scale": 3}
## Windows device names, refused as path segments.
const RESERVED_NAMES := ["con", "prn", "aux", "nul", "com0", "com1", "com2", "com3", "com4", "com5", "com6",
		"com7", "com8", "com9", "lpt0", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"]

## Point markers: only a transform (a mesh with that name is hidden).
const POINTS := ["grip", "grip_2", "muzzle", "mag_well", "sight", "opening", "spout", "contents", "rack",
		"spit", "fire", "light"]
const NUMBERED_POINTS := ["burner"]
## Moving parts: drawn; their transform and part index are kept for animating them later.
const PARTS := ["lid"]
const NUMBERED_PARTS := ["door", "drawer", "handle", "knob"]
const COLLIDER_SUFFIX := "-convcolonly"
## Movers (block L8): the parts furniture opens (Grabbable.part), at most MAX_MOVERS per model; the rest stay put.
const MAX_MOVERS := 16
const DOOR_MAX := deg_to_rad(110.0)   # how far a door_N turns open
const LID_MAX := deg_to_rad(100.0)    # how far a lid turns open
const DRAWER_OUT := 0.8               # share of a drawer's depth it slides out
const DRAWER_MIN := 0.05              # metres a drawer slides out at least
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
	## Collider meshes from `<name>-convcolonly` (hidden): [Mesh, Transform3D]. Make the shape with
	## ModelLibrary.collider_shape on the main thread when it is needed.
	var colliders: Array = []
	var aabb := AABB()
	var triangles := 0
	## Registry material this variant is tinted with ("" = the model as made).
	var tint := ""
	## Drawn mesh -> the glTF importer's copy of it (CPU-side arrays), which tinted variants are made from.
	var sources := {}
	## Decoded bytes of its images (counted toward MAX_IMAGE_BYTES while it is cached).
	var image_bytes := 0
	## The mover (lid, door_N, drawer_N; "" none) each of `parts` moves with: its nearest such marker, itself
	## included (a mover inside another one moves with the outer one).
	var part_owner := PackedStringArray()
	## The mover each of `surfaces` moves with ("" none).
	var surface_owner := PackedStringArray()
	## Marker name -> the mover it is inside (handle_N, surface_N, ...; the mover itself not listed).
	var marker_owner := {}
	## The doors, drawers and lids furniture opens (Mover, at most MAX_MOVERS), in the order lid, door_N, drawer_N.
	var movers: Array = []
	## Index into `movers` of the mover each of `surfaces` moves with, -1 for the ones that stay put.
	var surface_mover := PackedInt32Array()
	## The model without its movers' meshes (furniture that opens them draws this still); null without movers.
	var still: Model

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


## A door, drawer or lid of a model that opens (docs/MODELS.md, block L8): what Grabbable.part needs, in the
## marker's own space ("pivot space"). Read-only once made (the meshing worker reads it).
class Mover:
	var name := ""                 # lid, door_N or drawer_N
	var kind := ""                 # door, drawer or lid (Grabbable.part's kind)
	var pivot := Transform3D()     # model space: the marker (on the hinge line, or the slide's origin)
	var axis := Vector3.UP         # pivot space, unit: positive amounts turn (right-hand rule) or slide it open
	var max_amount := 0.0          # radians, metres for drawers
	var size := AABB()             # pivot space: the bounds of its meshes
	var handle := Transform3D()    # pivot space: its first handle_N (has_handle), else Grabbable picks one
	var has_handle := false
	var meshes: Array = []         # [Mesh, Transform3D in pivot space]
	var surfaces: Array = []       # [Transform3D in pivot space, Rect2]: its surface_N planes (items ride along)


## Folder the registry's `model` paths are relative to (assets/models).
var root := ""
## Read from other threads through get_warnings().
var warnings := PackedStringArray()
## Caps (tests lower them).
var max_file_bytes := MAX_FILE_BYTES
var max_nodes := MAX_NODES
var max_triangles := MAX_TRIANGLES
var max_markers := MAX_MARKERS
var max_parts := MAX_PARTS
var max_models := MAX_MODELS
var max_failed := MAX_FAILED
var max_image_bytes := MAX_IMAGE_BYTES
var _mutex := Mutex.new()
var _cache := {}    # case-folded relative path -> Model
var _failed := {}   # case-folded relative path -> true (loads that failed; capped at max_failed)
var _image_bytes := 0   # decoded image bytes of the loaded models
var _full_warned := false
var _failed_warned := false
var max_tinted := MAX_TINTED
var _tinted := {}  # "path|material" -> tinted Model (at most MAX_TINTED)
var _tint_warned := false
var max_total_triangles := MAX_TOTAL_TRIANGLES
var _triangle_total := 0   # of the cached models and tinted copies
var _mesh_warned := false


## The model at a registry path, or null (missing, outside the folder, or a bad file: see warnings).
## Safe to call from several threads. The file is read outside the lock, so a slow load never holds up
## another thread (two threads may read the same file at once; the first model kept is the one both get).
func get_model(rel: String) -> Model:
	var key := rel.left(MAX_PATH + 1).to_lower()
	_mutex.lock()
	var m: Model = _cache.get(key)
	var done := m != null or _failed.has(key) or not _room_to_load()
	_mutex.unlock()
	if done:
		return m
	var made := _load(rel)
	_mutex.lock()
	m = _cache.get(key)
	if m == null and not _failed.has(key):
		m = _keep(key, made, rel)
	_mutex.unlock()
	return m


## The model at a registry path tinted toward a palette material (CddaPalette.MATERIALS), cached: the same
## object for the same path and material. A name that isn't a palette material ("" included) gives the
## model as made, and so does any new variant past MAX_TINTED (with a warning); null when the model
## doesn't load.
func get_tinted(rel: String, material: String) -> Model:
	var m := get_model(rel)
	if m == null or not CddaPalette.MATERIALS.has(material):
		return m
	var key := m.path + "|" + material
	_mutex.lock()   # the meshing worker and the main thread both ask
	var t: Model = _tinted.get(key)
	var room := t == null and _room_to_tint(m)
	_mutex.unlock()
	if t != null:
		return t
	if not room:
		return m
	var made := tinted(m, CddaPalette.material(material))   # outside the lock, like loads
	made.tint = material
	_mutex.lock()
	t = _tinted.get(key)
	if t == null:
		if _room_to_tint(m):
			_tinted[key] = made
			_triangle_total += made.triangles
			t = made
		else:
			t = m
	_mutex.unlock()
	return t


## Whether another tinted variant of m fits (called with the mutex held; warns once when not).
func _room_to_tint(m: Model) -> bool:
	if _tinted.size() >= max_tinted:
		if not _tint_warned:
			_warn("more than %d tinted models, the rest are drawn untinted" % max_tinted)
			_tint_warned = true
		return false
	if _triangle_total + m.triangles > max_total_triangles:
		if not _mesh_warned:
			_warn("over the mesh budget for models (%d triangles), the rest are drawn untinted" % max_total_triangles)
			_mesh_warned = true
		return false
	return true


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
			meshes[mesh] = _tinted_mesh(mesh, m.sources.get(mesh), factor, materials, plain)
		t.parts.append([meshes[mesh], p[1]])
	t.part_owner = m.part_owner
	t.surface_owner = m.surface_owner
	t.marker_owner = m.marker_owner
	make_movers(t)   # the same movers, with the tinted meshes (m's warnings were given when it loaded)
	return t


## A copy of `mesh` with tinted materials, made from the importer's CPU-side copy `src` (copying the drawn mesh
## would read it back from the renderer, which waits on the main thread). Without one: the mesh as made.
static func _tinted_mesh(mesh: Mesh, src: Variant, factor: Color, materials: Dictionary, plain: Array) -> Mesh:
	if not src is ImporterMesh:
		return mesh
	var copy := (src as ImporterMesh).duplicate() as ImporterMesh
	if copy == null or copy.get_surface_count() == 0:
		return mesh
	for s in copy.get_surface_count():
		var mat := copy.get_surface_material(s)
		if mat == null:
			if plain[0] == null:
				var sm := StandardMaterial3D.new()
				sm.albedo_color = factor
				plain[0] = sm
			copy.set_surface_material(s, plain[0])
		elif mat is BaseMaterial3D:
			if not materials.has(mat):
				var tm := mat.duplicate() as BaseMaterial3D
				tm.albedo_color = (mat as BaseMaterial3D).albedo_color * factor
				materials[mat] = tm
			copy.set_surface_material(s, materials[mat])
	var out := copy.get_mesh()
	return out if out != null else mesh


## A copy of the warnings, safe while another thread loads models.
func get_warnings() -> PackedStringArray:
	_mutex.lock()
	var out := warnings.duplicate()
	_mutex.unlock()
	return out


## Whether a path not tried before may be loaded: within the model and failure caps (called with the mutex
## held; warns once when not).
func _room_to_load() -> bool:
	if _cache.size() >= max_models:
		if not _full_warned:
			_warn("more than %d models, the rest aren't loaded" % max_models)
			_full_warned = true
		return false
	if _failed.size() >= max_failed:
		if not _failed_warned:
			_warn("more than %d models failed to load, the rest aren't tried" % max_failed)
			_failed_warned = true
		return false
	return true


## Keeps a model just loaded under `key` within the caps and budgets (called with the mutex held); a failed
## or refused load is remembered as failed. Returns the model kept, or null.
func _keep(key: String, m: Model, rel: String) -> Model:
	if m != null and _cache.size() >= max_models:   # filled by other threads meanwhile
		if not _full_warned:
			_warn("more than %d models, the rest aren't loaded" % max_models)
			_full_warned = true
		m = null
	elif m != null and _image_bytes + m.image_bytes > max_image_bytes:
		_warn("%s: over the image memory budget for models" % _clean(rel, 80))
		m = null
	elif m != null and _triangle_total + m.triangles > max_total_triangles:
		_warn("%s: over the mesh budget for models (%d triangles)" % [_clean(rel, 80), max_total_triangles])
		m = null
	if m == null:
		_failed[key] = true
		return null
	_cache[key] = m
	_image_bytes += m.image_bytes
	_triangle_total += m.triangles
	return m


## Absolute path of a registry path, or "" when it isn't a plain relative path inside root (no links or
## junctions below root, no device names).
func resolve(rel: String) -> String:
	if root.is_empty() or rel.length() > MAX_PATH or not rel.to_lower().ends_with(".glb") or rel.begins_with("/"):
		return ""
	for c in rel:
		if not ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c in "_-./"):
			return ""
	var segs := rel.split("/")
	for seg in segs:
		if seg.is_empty() or seg == "." or seg == ".." or seg.ends_with(".") or seg.get_slice(".", 0).to_lower() in RESERVED_NAMES:
			return ""
	var base := root.simplify_path()
	var full := base.path_join(rel).simplify_path()
	if not full.begins_with(base + "/"):
		return ""
	var da := DirAccess.open(base)
	if da == null:
		return ""
	var at := base
	for seg in segs:
		at = at.path_join(seg)
		if da.is_link(at):
			return ""
	return full


func _load(rel: String) -> Model:
	var name := _clean(rel, 80)
	var full := resolve(rel)
	if full.is_empty():
		_warn("%s: not a .glb path inside the models folder" % name)
		return null
	if not FileAccess.file_exists(full):
		_warn("%s: missing" % name)
		return null
	var f := FileAccess.open(full, FileAccess.READ)
	if f == null:
		_warn("%s: cannot open" % name)
		return null
	var size := f.get_length()
	if size > max_file_bytes:
		_warn("%s: larger than %d bytes" % [name, max_file_bytes])
		return null
	var bytes := f.get_buffer(size)
	f.close()
	if bytes.size() != size:
		_warn("%s: cannot read" % name)
		return null
	var info := {}
	var why := check_glb(bytes, info)
	if not why.is_empty():
		_warn("%s: %s" % [name, why])
		return null
	var image_bytes: int = info.get("pixels", 0) * 4
	_mutex.lock()
	var over := image_bytes > 0 and _image_bytes + image_bytes > max_image_bytes
	_mutex.unlock()
	if over:
		_warn("%s: over the image memory budget for models" % name)
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	state.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED   # never writes files
	state.create_animations = false
	if doc.append_from_buffer(bytes, "", state) != OK:
		_warn("%s: Godot can't read this glTF" % name)
		return null
	var scene := doc.generate_scene(state)
	if scene == null:
		_warn("%s: Godot can't build this glTF" % name)
		return null
	var m := Model.new()
	m.path = rel
	m.image_bytes = image_bytes
	why = _read(scene, m)
	scene.free()
	if not why.is_empty():
		_warn("%s: %s" % [name, why])
		return null
	var used := {}
	for p: Array in m.parts:
		used[p[0]] = true
	for gm: GLTFMesh in state.get_meshes():   # the importer's copies: what tinted variants are made from
		var im := gm.mesh
		if im != null and im.get_surface_count() > 0:
			var drawn := im.get_mesh()   # made once by the importer: the mesh the scene draws
			if used.has(drawn):
				im.remove_meta("extras")
				m.sources[drawn] = im
	for w in make_movers(m):
		_warn("%s: %s" % [name, w])
	return m


## "" when the bytes are a .glb within the caps, else why not. Checks the container and the glTF JSON
## before Godot parses anything. Sets out["pixels"] to the decoded pixels of the file's images.
func check_glb(bytes: PackedByteArray, out: Dictionary = {}) -> String:
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
	var chunk := bytes.slice(20, 20 + jlen)
	var sorted := chunk.duplicate()
	sorted.sort()
	if not sorted.is_empty() and sorted[sorted.size() - 1] >= 0x80:
		return "the glTF JSON must be plain ASCII"
	var json := JSON.new()
	if json.parse(chunk.get_string_from_ascii()) != OK or not json.data is Dictionary:
		return "bad glTF JSON"
	return _check_json(json.data, bytes, bin_at, bin_len, out)


func _check_json(g: Dictionary, bytes: PackedByteArray, bin_at: int, bin_len: int, out: Dictionary) -> String:
	var limits := {"nodes": max_nodes, "meshes": MAX_MESHES, "accessors": MAX_ACCESSORS, "bufferViews": MAX_ACCESSORS,
			"buffers": 1, "materials": MAX_MATERIALS, "textures": MAX_TEXTURES, "samplers": MAX_TEXTURES,
			"images": MAX_IMAGES, "scenes": 8, "extensionsRequired": 16, "extensionsUsed": 32}
	for key: String in limits:
		if g.has(key) and not g[key] is Array:
			return "%s is not a list" % key
		if _list(g, key).size() > limits[key]:
			return "more than %d %s" % [limits[key], key]
	for key: String in UNSUPPORTED:
		if _has_items(g, key):
			return "%s are not supported" % key
	for key: String in ["extensionsRequired", "extensionsUsed"]:
		for e: Variant in _list(g, key):
			if not e is String or not e in EXTENSIONS_OK:
				return "uses an unsupported extension (%s)" % _clean(str(e), 64)
	var other := _other_extension(g)
	if not other.is_empty():
		return "uses an unsupported extension (%s)" % other
	var buffers := _list(g, "buffers")
	var buf_len := 0
	for b: Variant in buffers:
		if not b is Dictionary or (b as Dictionary).has("uri"):
			return "buffers must be the .glb's own"
		buf_len = _int(b.get("byteLength"), 0, bin_len)
		if buf_len < 0:
			return "buffers must be the .glb's own"
	var views: Array = []   # [byte offset in the buffer, byte length, byte stride or 0]
	for v: Variant in _list(g, "bufferViews"):
		if not v is Dictionary or _int(v.get("buffer"), 0, buffers.size() - 1) < 0:
			return "bad buffer view"
		var off := _int(v.get("byteOffset", 0), 0, buf_len)
		var n := _int(v.get("byteLength"), 1, buf_len)
		if off < 0 or n < 0 or off + n > buf_len:
			return "buffer view outside the buffer"
		var stride := 0
		if v.has("byteStride"):
			stride = _int(v["byteStride"], 4, 252)
			if stride < 0 or stride % 4 != 0:
				return "bad buffer view stride"
		if v.has("target") and _int(v["target"], 34962, 34963) < 0:
			return "bad buffer view target"
		views.append([off, n, stride])
	var why := _check_images(g, views, bytes, bin_at, out)
	if not why.is_empty():
		return why
	var acc: Array = []   # [count, component type, type, byte offset in the file, view has a stride]
	for a: Variant in _list(g, "accessors"):
		why = _check_accessor(a, views, bin_at, acc)
		if not why.is_empty():
			return why
	why = _check_materials(g)
	if not why.is_empty():
		return why
	var tris := PackedInt32Array()
	var prims := PackedInt32Array()
	why = _check_meshes(g, acc, bytes, tris, prims)
	if not why.is_empty():
		return why
	return _check_nodes(g, tris, prims)


## Embedded PNG or JPEG images: format matches mimeType, sides and pixels in all within the caps.
static func _check_images(g: Dictionary, views: Array, bytes: PackedByteArray, bin_at: int, out: Dictionary) -> String:
	var pixels := 0
	for img: Variant in _list(g, "images"):
		if not img is Dictionary or (img as Dictionary).has("uri"):
			return "images must be embedded"
		var vi := _int(img.get("bufferView"), 0, views.size() - 1)
		if vi < 0 or views[vi][2] != 0:
			return "bad image"
		var at: int = bin_at + views[vi][0]
		var n: int = views[vi][1]
		var mime := _image_mime(bytes, at, n)
		var said: Variant = img.get("mimeType", mime)
		if mime.is_empty() or not said is String or said != mime:
			return "images must be PNG or JPEG"
		var size := _image_size(bytes, at, n)
		if size.x <= 0 or size.y <= 0:
			return "bad image"
		if maxi(size.x, size.y) > MAX_IMAGE_SIDE:
			return "an image is larger than %d px" % MAX_IMAGE_SIDE
		pixels += size.x * size.y
		if pixels > MAX_IMAGE_PIXELS:
			return "images have more than %d pixels in all" % MAX_IMAGE_PIXELS
	out["pixels"] = pixels
	return ""


## One accessor: a buffer view in range, known component type and type, offsets aligned, every element
## inside the view (stride = element size without a view stride), no sparse data. Appends its info to acc.
static func _check_accessor(a: Variant, views: Array, bin_at: int, acc: Array) -> String:
	if not a is Dictionary:
		return "bad accessor"
	var n := _int(a.get("count"), 1, MAX_ACCESSOR_COUNT)
	if n < 0:
		return "an accessor needs 1 to %d elements" % MAX_ACCESSOR_COUNT
	if a.has("sparse"):
		return "sparse accessors are not supported"
	var vi := _int(a.get("bufferView"), 0, views.size() - 1)
	if vi < 0:
		return "an accessor needs a buffer view"
	var ct := _int(a.get("componentType"), 5120, 5126)
	var type: Variant = a.get("type")
	if not COMPONENT_BYTES.has(ct) or not type is String or not TYPE_SHAPE.has(type):
		return "bad accessor type"
	var cb: int = COMPONENT_BYTES[ct]
	var shape: Vector2i = TYPE_SHAPE[type]
	# matrix columns are padded to 4 bytes
	var size := shape.y * cb if shape.x == 1 else shape.x * ((shape.y * cb + 3) & ~3)
	var view: Array = views[vi]
	var view_off: int = view[0]
	var view_len: int = view[1]
	var stride: int = view[2] if view[2] > 0 else size
	var off := _int(a.get("byteOffset", 0), 0, view_len)
	if off < 0 or off % cb != 0 or (view_off + off) % cb != 0:
		return "bad accessor offset"
	if stride < size:
		return "a buffer view stride is smaller than its accessor's elements"
	if off + stride * (n - 1) + size > view_len:
		return "an accessor reaches past its buffer view"
	for k: String in ["min", "max"]:
		if a.has(k) and (not a[k] is Array or (a[k] as Array).size() != shape.x * shape.y):
			return "bad accessor %s" % k
	if a.has("normalized") and not a["normalized"] is bool:
		return "bad accessor"
	acc.append([n, ct, type, bin_at + view_off + off, view[2] > 0])
	return ""


## Samplers use known values; textures, samplers and images referenced by index are in range.
static func _check_materials(g: Dictionary) -> String:
	var n_images := _list(g, "images").size()
	var n_textures := _list(g, "textures").size()
	var n_samplers := _list(g, "samplers").size()
	for s: Variant in _list(g, "samplers"):
		if not s is Dictionary:
			return "bad texture sampler"
		for k: String in SAMPLER_VALUES:
			if s.has(k) and not (_int(s[k], 0, 0xFFFF) in SAMPLER_VALUES[k]):
				return "bad texture sampler"
	for t: Variant in _list(g, "textures"):
		if not t is Dictionary or (t.has("source") and _int(t["source"], 0, n_images - 1) < 0):
			return "bad texture image"
		if t.has("sampler") and _int(t["sampler"], 0, n_samplers - 1) < 0:
			return "bad texture sampler"
	for mat: Variant in _list(g, "materials"):
		if not mat is Dictionary:
			return "bad material"
		var slots: Array = []
		for k: String in ["normalTexture", "occlusionTexture", "emissiveTexture"]:
			if mat.has(k):
				slots.append(mat[k])
		if mat.has("pbrMetallicRoughness"):
			var pbr: Variant = mat["pbrMetallicRoughness"]
			if not pbr is Dictionary:
				return "bad material"
			for k: String in ["baseColorTexture", "metallicRoughnessTexture"]:
				if pbr.has(k):
					slots.append(pbr[k])
		for t: Variant in slots:
			if not t is Dictionary or _int(t.get("index"), 0, n_textures - 1) < 0 or (t.has("texCoord") and _int(t["texCoord"], 0, 7) < 0):
				return "bad material texture"
	return ""


## Mesh primitives: triangle lists with a POSITION, every attribute of the same count, indices a multiple
## of 3 and below the vertex count; vertices and triangles capped over every mesh in the file (used or
## not). Appends each mesh's triangles to tris and its primitive count to prims.
func _check_meshes(g: Dictionary, acc: Array, bytes: PackedByteArray, tris: PackedInt32Array, prims: PackedInt32Array) -> String:
	var n_materials := _list(g, "materials").size()
	var primitives := 0
	var vertices := 0
	var corners := 0
	for mesh: Variant in _list(g, "meshes"):
		if not mesh is Dictionary or not mesh.get("primitives") is Array:
			return "bad mesh"
		if _has_items(mesh, "weights"):
			return "morph targets are not supported"
		if (mesh["primitives"] as Array).size() > MAX_MESH_PRIMITIVES:
			return "a mesh has more than %d primitives" % MAX_MESH_PRIMITIVES
		prims.append((mesh["primitives"] as Array).size())
		var t := 0
		for p: Variant in mesh["primitives"]:
			primitives += 1
			if primitives > MAX_PRIMITIVES:
				return "more than %d mesh primitives" % MAX_PRIMITIVES
			if not p is Dictionary or not p.get("attributes") is Dictionary:
				return "bad mesh primitive"
			if _int(p.get("mode", 4), 4, 4) < 0:
				return "only triangle meshes are supported (mode 4)"
			if _has_items(p, "targets"):
				return "morph targets are not supported"
			if p.has("material") and _int(p["material"], 0, n_materials - 1) < 0:
				return "bad mesh primitive material"
			var attrs: Dictionary = p["attributes"]
			var pos := _int(attrs.get("POSITION"), 0, acc.size() - 1)
			if pos < 0:
				return "a mesh primitive has no POSITION"
			var nv: int = acc[pos][0]
			if nv > MAX_PRIMITIVE_VERTICES:
				return "a mesh primitive has more than %d vertices" % MAX_PRIMITIVE_VERTICES
			vertices += nv
			if vertices > MAX_VERTICES:
				return "more than %d vertices in all meshes" % MAX_VERTICES
			for k: Variant in attrs:
				var ai := _int(attrs[k], 0, acc.size() - 1)
				if not k is String or ai < 0 or not _attribute_type_ok(k, acc[ai][2]):
					return "bad mesh attribute"
				if acc[ai][0] != nv:
					return "mesh attributes differ in count"
			var corner_n := nv
			if p.has("indices"):
				var ii := _int(p["indices"], 0, acc.size() - 1)
				if ii < 0 or acc[ii][2] != "SCALAR" or not acc[ii][1] in [5121, 5123, 5125] or acc[ii][4]:
					return "bad mesh indices"
				corner_n = acc[ii][0]
				if corner_n % 3 != 0:
					return "a mesh index count is not a multiple of 3"
				if _index_max(bytes, acc[ii][3], corner_n, acc[ii][1]) >= nv:
					return "a mesh index is past its vertices"
			elif nv % 3 != 0:
				return "a mesh vertex count is not a multiple of 3"
			corners += corner_n
			if corners > 3 * max_triangles:
				return "more than %d triangles in its meshes" % max_triangles
			t += corner_n / 3
		tris.append(t)
	return ""


## Node tree: valid links, one parent each, no cycles, depth, finite transforms, no skins or cameras,
## markers and triangles over all mesh uses. Scenes: index in range, root nodes listed once, parentless.
func _check_nodes(g: Dictionary, tris: PackedInt32Array, prims: PackedInt32Array) -> String:
	var nodes := _list(g, "nodes")
	var parent := PackedInt32Array()
	parent.resize(nodes.size())
	parent.fill(-1)
	var triangles := 0
	var drawn := 0
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
		for k: String in ["skin", "camera"]:
			if n.has(k):
				return "%ss are not supported" % k
		if _has_items(n, "weights"):
			return "morph targets are not supported"
		for k: String in NODE_TRS:
			if n.has(k) and not _finite_list(n[k], NODE_TRS[k]):
				return "bad node transform"
		if n.has("mesh"):
			var mi := _int(n["mesh"], 0, tris.size() - 1)
			if mi < 0:
				return "bad node mesh"
			triangles += tris[mi]
			drawn += prims[mi]
			if drawn > MAX_DRAWN_SURFACES:
				return "more than %d mesh surfaces drawn" % MAX_DRAWN_SURFACES
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
	var scenes := _list(g, "scenes")
	if g.has("scene") and _int(g["scene"], 0, scenes.size() - 1) < 0:
		return "bad scene index"
	for s: Variant in scenes:
		if not s is Dictionary or (s.has("nodes") and not s["nodes"] is Array):
			return "bad scene"
		var seen := {}
		for r: Variant in s.get("nodes", []):
			var ri := _int(r, 0, nodes.size() - 1)
			if ri < 0 or seen.has(ri) or parent[ri] >= 0:
				return "bad scene nodes"
			seen[ri] = true
	if markers > max_markers:
		return "more than %d markers" % max_markers
	if triangles > max_triangles:
		return "%d triangles, more than %d" % [triangles, max_triangles]
	return ""


## Reads the built scene into m: drawn parts, markers, surfaces, fill, colliders. "" or why it failed.
## Transforms and bounds must be finite; the whole model must fit in MAX_MODEL_SIZE a side.
func _read(scene: Node, m: Model) -> String:
	var stack: Array = [[scene, Transform3D.IDENTITY, false, ""]]   # node, parent transform, hidden, mover
	var surfaces := {}
	var visited := 0
	var bounds := AABB()
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var n: Node = e[0]
		var xf: Transform3D = e[1]
		var hidden: bool = e[2]
		var owner: String = e[3]
		visited += 1
		if visited > max_nodes + 1:
			return "more than %d nodes" % max_nodes
		if n is Node3D:
			xf = xf * (n as Node3D).transform
		if not xf.is_finite():
			return "a node transform is not a finite number"
		var name := String(n.name)
		var kind := marker_kind(name)
		var mesh: Mesh = (n as MeshInstance3D).mesh if n is MeshInstance3D else null
		var box := AABB(xf.origin, Vector3.ZERO)
		if mesh != null:
			if not mesh.get_aabb().is_finite():
				return "mesh bounds are not finite numbers"
			box = xf * mesh.get_aabb()
		if not box.is_finite():
			return "mesh bounds are not finite numbers"
		bounds = box if visited == 1 else bounds.merge(box)
		if kind != Marker.NONE and kind != Marker.COLLIDER:
			m.markers[name] = xf
			if not owner.is_empty():
				m.marker_owner[name] = owner
		if owner.is_empty() and is_mover(name):
			owner = name
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
					m.colliders.append([mesh, xf])
		if mesh != null:
			m.triangles += _triangles(mesh)
			if not hidden and kind != Marker.POINT:
				if m.parts.size() >= max_parts:
					return "more than %d drawn parts" % max_parts
				if kind == Marker.PART:
					m.marker_parts[name] = m.parts.size()
				var part_box := xf * mesh.get_aabb()
				m.aabb = part_box if m.parts.is_empty() else m.aabb.merge(part_box)
				_drop_extras(mesh)
				m.parts.append([mesh, xf])
				m.part_owner.append(owner)
		for c in n.get_children():
			stack.append([c, xf, hidden, owner])
	if m.markers.size() + m.colliders.size() > max_markers:
		return "more than %d markers" % max_markers
	if m.triangles > max_triangles:
		return "%d triangles, more than %d" % [m.triangles, max_triangles]
	if m.parts.is_empty():
		return "no visible mesh"
	if maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z)) > MAX_MODEL_SIZE:
		return "wider than %d m" % int(MAX_MODEL_SIZE)
	var keys := surfaces.keys()
	keys.sort()
	for k: int in keys:
		m.surfaces.append(surfaces[k])
		m.surface_owner.append(m.marker_owner.get("surface_%d" % k, ""))
	return ""


## The file's `extras` (kept by the importer as metadata) go: cached models don't carry them.
static func _drop_extras(mesh: Mesh) -> void:
	mesh.remove_meta("extras")
	for s in mesh.get_surface_count():
		var mat := mesh.surface_get_material(s)
		if mat != null:
			mat.remove_meta("extras")


## Whether a marker name is a mover: lid, door_N or drawer_N.
static func is_mover(name: String) -> bool:
	return marker_kind(name) == Marker.PART and (name == "lid" or name.begins_with("door_") or name.begins_with("drawer_"))


## Fills m.movers, m.surface_mover and m.still from its parts, markers and owners (docs/MODELS.md, "Doors,
## drawers and lids that open"): a mover that can't open (a flat transform, no mesh, meshes or handle more than
## Grabbable.MAX_EXTENT from its origin) stays put with the body. Returns why, one line per mover left out.
static func make_movers(m: Model) -> PackedStringArray:
	var why := PackedStringArray()
	m.movers = []
	m.still = null
	m.surface_mover = PackedInt32Array()
	m.surface_mover.resize(m.surfaces.size())
	m.surface_mover.fill(-1)
	if m.part_owner.size() != m.parts.size() or m.surface_owner.size() != m.surfaces.size():
		return why
	var names := PackedStringArray(["lid"] if m.markers.has("lid") else [])
	names.append_array(m.numbered("door"))
	names.append_array(m.numbered("drawer"))
	var moving := {}   # mover name -> index into m.movers
	var over := PackedStringArray()   # past MAX_MOVERS
	for name in names:
		if m.marker_owner.has(name):
			why.append("%s is inside %s and moves with it" % [name, m.marker_owner[name]])
			continue
		if m.movers.size() >= MAX_MOVERS:
			over.append(name)
			continue
		var mv: Variant = _mover(m, name)
		if mv is String:
			why.append("%s stays put: %s" % [name, mv])
			continue
		moving[name] = m.movers.size()
		m.movers.append(mv)
	if not over.is_empty():
		why.append("more than %d doors, drawers and lids: %s and %d more stay put" % [MAX_MOVERS, over[0], over.size() - 1])
	if moving.is_empty():
		return why
	for k in m.surfaces.size():
		var owner := m.surface_owner[k]
		if not moving.has(owner):
			continue
		var mover: Mover = m.movers[moving[owner]]
		var s: Array = m.surfaces[k]
		var xf: Transform3D = mover.pivot.affine_inverse() * (s[0] as Transform3D) * Transform3D(Basis.IDENTITY, Vector3(0, s[2], 0))
		var rect: Rect2 = s[1]
		if mover.surfaces.size() >= Grabbable.MAX_SURFACES or not xf.is_finite() or xf.origin.length() > Grabbable.MAX_EXTENT \
				or not rect.is_finite() or rect.size.length() > Grabbable.MAX_EXTENT * 2.0:
			why.append("a surface on %s stays put (more than %d there, or too far from it)" % [owner, Grabbable.MAX_SURFACES])
			continue
		mover.surfaces.append([xf, rect.abs()])
		m.surface_mover[k] = moving[owner]
	var still := Model.new()
	still.path = m.path
	still.markers = m.markers
	still.marker_owner = m.marker_owner
	still.surfaces = m.surfaces
	still.surface_owner = m.surface_owner
	still.surface_mover = m.surface_mover
	still.fill = m.fill
	still.colliders = m.colliders
	still.aabb = m.aabb
	still.triangles = m.triangles
	still.tint = m.tint
	for i in m.parts.size():
		if moving.has(m.part_owner[i]):
			continue
		for nm: String in m.marker_parts:
			if m.marker_parts[nm] == i:
				still.marker_parts[nm] = still.parts.size()
		still.parts.append(m.parts[i])
		still.part_owner.append(m.part_owner[i])
	m.still = still
	return why


## The mover named `name` of m, or why it can't open.
static func _mover(m: Model, name: String) -> Variant:
	var pivot: Transform3D = m.markers[name]
	if not pivot.is_finite() or absf(pivot.basis.determinant()) < 1e-6:
		return "its transform is flat"
	var inv := pivot.affine_inverse()
	var mv := Mover.new()
	mv.name = name
	mv.pivot = pivot
	var first := true
	for i in m.parts.size():
		if m.part_owner[i] != name:
			continue
		var local := inv * (m.parts[i][1] as Transform3D)
		mv.meshes.append([m.parts[i][0], local])
		var b := local * (m.parts[i][0] as Mesh).get_aabb()
		mv.size = b if first else mv.size.merge(b)
		first = false
	if mv.meshes.is_empty():
		return "no mesh moves with it"
	var box := mv.size
	if not box.is_finite() or box.size.length() < 0.01 or box.position.length() > Grabbable.MAX_EXTENT \
			or box.end.length() > Grabbable.MAX_EXTENT:
		return "its meshes are empty or reach more than %.0f m from its origin" % Grabbable.MAX_EXTENT
	# The model's up and front (+Z) in pivot space.
	var up := (inv.basis * Vector3.UP).normalized()
	var front := (inv.basis * Vector3.BACK).normalized()
	if not up.is_finite() or not front.is_finite() or up.is_zero_approx() or front.is_zero_approx():
		return "its transform is flat"
	if name.begins_with("drawer_"):
		mv.kind = "drawer"
		mv.axis = front
		var depth := absf(front.x) * box.size.x + absf(front.y) * box.size.y + absf(front.z) * box.size.z
		mv.max_amount = clampf(DRAWER_OUT * depth, DRAWER_MIN, Grabbable.MAX_SLIDE)
	else:
		# A door turns about the model's vertical through its origin, a lid about its own X; the sign is the
		# one that moves the middle of its meshes toward the front (doors) or up (lids).
		var lid := name == "lid"
		mv.kind = "lid" if lid else "door"
		var line := Vector3.RIGHT if lid else up
		var c := box.get_center()
		var r := c - line * c.dot(line)
		var opens := line.cross(r).dot(up if lid else front)
		mv.axis = line if opens > 1e-4 else -line   # no clear side: as if hinged on the left (doors) or the back (lids)
		mv.max_amount = LID_MAX if lid else DOOR_MAX
	for h in m.numbered("handle"):   # the first handle on it that is near it (else Grabbable picks a point)
		if m.marker_owner.get(h, "") == name:
			var hd := inv * (m.markers[h] as Transform3D)
			if hd.is_finite() and hd.origin.length() <= Grabbable.MAX_EXTENT:
				mv.handle = hd
				mv.has_handle = true
				break
	return mv


## A convex shape for a collider mesh of Model.colliders, from at most max_points of its finite vertices
## (evenly subsampled). Call on the main thread when the collider is needed. null without vertices.
static func collider_shape(mesh: Mesh, max_points := MAX_HULL_POINTS) -> ConvexPolygonShape3D:
	if mesh == null or max_points < 1:
		return null
	var all := PackedVector3Array()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			all.append_array(arrays[Mesh.ARRAY_VERTEX])
	var points := PackedVector3Array()
	var step := maxi(1, ceili(all.size() / float(max_points)))
	for i in range(0, all.size(), step):
		if all[i].is_finite():
			points.append(all[i])
	if points.is_empty():
		return null
	var cloud := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	cloud.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	return cloud.create_convex_shape(true, false)


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


## Whether an attribute's accessor type fits its name (custom attributes: any type).
static func _attribute_type_ok(name: String, type: String) -> bool:
	if name == "POSITION" or name == "NORMAL":
		return type == "VEC3"
	if name == "TANGENT":
		return type == "VEC4"
	match name.get_slice("_", 0):
		"TEXCOORD":
			return type == "VEC2"
		"COLOR":
			return type == "VEC3" or type == "VEC4"
		"JOINTS", "WEIGHTS":
			return type == "VEC4"
	return true


## Largest of n tightly packed indices (u8, u16 or u32) at `at`, found by sorting copies; u32 values from
## 2^31 up count as 0x7FFFFFFF.
static func _index_max(bytes: PackedByteArray, at: int, n: int, ct: int) -> int:
	match ct:
		5121:
			var s := bytes.slice(at, at + n)
			s.sort()
			return s[n - 1]
		5123:
			# the high halves of 32-bit pairs read from `at` and from `at + 2` cover every value but the first
			var top := bytes.decode_u16(at)
			for start: int in [at, at + 2]:
				var pairs := (n - (start - at) / 2) / 2
				if pairs > 0:
					var s := bytes.slice(start, start + 4 * pairs).to_int32_array()
					s.sort()
					var neg := s.bsearch(0) - 1   # high half from 0x8000 up reads as negative
					var v: int = s[neg] if neg >= 0 else s[pairs - 1]
					top = maxi(top, (v >> 16) & 0xFFFF)
			return top
		5125:
			var s := bytes.slice(at, at + 4 * n).to_int32_array()
			s.sort()
			return s[n - 1] if s[0] >= 0 else 0x7FFFFFFF
	return 0x7FFFFFFF


## "image/png" or "image/jpeg" from the first bytes of an embedded image, else "".
static func _image_mime(bytes: PackedByteArray, at: int, n: int) -> String:
	if n < 24 or at < 0 or at + n > bytes.size():
		return ""
	if bytes.decode_u32(at) == 0x474E5089 and bytes.decode_u32(at + 4) == 0x0A1A0A0D:
		return "image/png"
	if bytes[at] == 0xFF and bytes[at + 1] == 0xD8:
		return "image/jpeg"
	return ""


## Width and height of an embedded PNG (IHDR) or JPEG (first SOF segment), (-1, -1) when unreadable.
## A JPEG is walked segment by segment from SOI, the way decoders do: only known segments (APPn, COM, DQT, DHT,
## DRI, DAC, SOFn; RSTn and TEM without a length), each length at least 2 and inside the image, fill bytes
## (FF FF) skipped. Anything else before the first SOF (FF 00, another SOI, EOI, SOS, unknown markers, a byte
## that isn't FF where a marker belongs) makes it unreadable.
static func _image_size(bytes: PackedByteArray, at: int, n: int) -> Vector2i:
	match _image_mime(bytes, at, n):
		"image/png":
			if bytes.decode_u32(at + 12) != 0x52444849:   # "IHDR"
				return Vector2i(-1, -1)
			return Vector2i(mini(_be(bytes, at + 16, 4), 0x7FFFFFFF), mini(_be(bytes, at + 20, 4), 0x7FFFFFFF))
		"image/jpeg":
			var i := at + 2
			var end := at + n
			while i + 2 <= end:
				if bytes[i] != 0xFF:
					return Vector2i(-1, -1)
				var mk := bytes[i + 1]
				if mk == 0xFF:   # fill byte before a marker
					i += 1
					continue
				if mk == 0x01 or (mk >= 0xD0 and mk <= 0xD7):   # TEM, RSTn: no length
					i += 2
					continue
				if not _jpeg_segment(mk) or i + 4 > end:
					return Vector2i(-1, -1)
				var length := _be(bytes, i + 2, 2)
				if length < 2 or i + 2 + length > end:
					return Vector2i(-1, -1)
				if _jpeg_sof(mk):
					if length < 8:
						return Vector2i(-1, -1)
					return Vector2i(_be(bytes, i + 7, 2), _be(bytes, i + 5, 2))
				i += 2 + length
	return Vector2i(-1, -1)


## A JPEG marker with a length that may come before the first SOF: APPn, COM, DQT, DHT, DRI, DAC or a SOFn.
static func _jpeg_segment(mk: int) -> bool:
	return (mk >= 0xE0 and mk <= 0xEF) or mk == 0xFE or mk == 0xDB or mk == 0xC4 or mk == 0xDD or mk == 0xCC \
			or _jpeg_sof(mk)


## SOF0..SOF15 (not DHT C4, JPG C8 or DAC CC).
static func _jpeg_sof(mk: int) -> bool:
	return mk >= 0xC0 and mk <= 0xCF and mk != 0xC4 and mk != 0xC8 and mk != 0xCC


static func _be(bytes: PackedByteArray, at: int, n: int) -> int:
	var v := 0
	for k in n:
		v = (v << 8) | bytes[at + k]
	return v


## The first name in an `extensions` object anywhere in the JSON (outside `extras`) that isn't in
## EXTENSIONS_OK, or "".
static func _other_extension(g: Dictionary) -> String:
	var stack: Array = [g]
	while not stack.is_empty():
		var v: Variant = stack.pop_back()
		if v is Dictionary:
			for k: Variant in v:
				var x: Variant = v[k]
				if k is String and k == "extras":
					continue
				if k is String and k == "extensions":
					if not x is Dictionary:
						return "extensions is not an object"
					for e: Variant in x:
						if not e is String or not e in EXTENSIONS_OK:
							return _clean(str(e), 64)
				if x is Dictionary or x is Array:
					stack.append(x)
		else:
			for x: Variant in v:
				if x is Dictionary or x is Array:
					stack.append(x)
	return ""


static func _list(g: Dictionary, key: String) -> Array:
	var v: Variant = g.get(key, [])
	return v if v is Array else []


## Whether d has key with anything but an empty list.
static func _has_items(d: Dictionary, key: String) -> bool:
	return d.has(key) and not (d[key] is Array and (d[key] as Array).is_empty())


## Whether v is a list of n finite numbers.
static func _finite_list(v: Variant, n: int) -> bool:
	if not v is Array or (v as Array).size() != n:
		return false
	for x: Variant in v:
		if not (x is float or x is int) or not is_finite(float(x)):
			return false
	return true


## A whole number in lo..hi from JSON (numbers come as floats), else -1.
static func _int(v: Variant, lo: int, hi: int) -> int:
	if not (v is float or v is int):
		return -1
	var f := float(v)
	if f != floorf(f) or f < lo or f > hi:
		return -1
	return int(f)


## Text from a file or the registry for a warning: control and direction characters replaced, capped.
static func _clean(s: String, cap: int) -> String:
	var out := ""
	for c in s.left(cap):
		var u := c.unicode_at(0)
		var bad := u < 0x20 or (u >= 0x7F and u < 0xA0) or (u >= 0x200B and u <= 0x200F) \
				or (u >= 0x202A and u <= 0x202E) or (u >= 0x2066 and u <= 0x2069)
		out += "?" if bad else c
	return out + ("..." if s.length() > cap else "")


func _warn(msg: String) -> void:
	var text := "model " + _clean(msg, MAX_WARNING_LEN)
	_mutex.lock()
	if warnings.size() < MAX_WARNINGS:
		warnings.append(text)
		push_warning(text)
	_mutex.unlock()
