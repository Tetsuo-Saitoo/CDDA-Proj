extends RefCounted
## Model loading (ModelLibrary, docs/MODELS.md): a tiny .glb built here with GLTFDocument, its markers,
## the caps, hostile files and paths, the strict glTF checks (one small file per rule), the cache, links,
## registry fallbacks, model props and item piles on model surfaces, monster models and their hit regions,
## and the game's own models (assets/models).
## Run from run_tests.gd; files go to model_test in the run's own folder (tests/test_dir.gd) and are removed
## afterwards.

const TestDir := preload("res://tests/test_dir.gd")

var _check: Callable
var _dir := ""


func run(check: Callable, data: Variant, tables: IdTables, scene: Callable, repo: Callable) -> void:
	print("models (.glb)")
	_check = check
	_dir = TestDir.global("model_test")
	_remove(_dir)
	DirAccess.make_dir_recursive_absolute(_dir.path_join("models/furniture"))
	DirAccess.make_dir_recursive_absolute(_dir.path_join("models/terrain"))
	DirAccess.make_dir_recursive_absolute(_dir.path_join("registry"))
	DirAccess.make_dir_recursive_absolute(_dir.path_join("registry_terrain"))
	var glb := cupboard_glb()
	_write("models/furniture/cupboard.glb", glb)
	_test_markers()
	_test_tint()
	_test_colliders()
	_test_caps(glb)
	_test_hostile(glb)
	_test_strict()
	_test_index_max()
	_test_cache(glb)
	_test_links(glb)
	_test_props(data, tables, scene, repo)
	_test_joins(data, tables, scene, repo)
	_test_terrain(glb, data, tables, scene, repo)
	_test_creature_model()
	_test_repo_models(repo)
	_remove(_dir)


## A 0.8 x 1.2 x 0.5 m cupboard: body, a door with a handle, two shelves (surface_2 listed first), a fill
## volume, a collider, a grip point and a spout drawn as a little box (hidden), a textured body.
static func cupboard_glb() -> PackedByteArray:
	var root := Node3D.new()
	root.name = "cupboard"
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.4, 0.3))
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(img)
	_box(root, "body", Vector3(0.8, 1.2, 0.5), Vector3(0, 0.6, 0)).material_override = mat
	var grip := Node3D.new()
	grip.name = "grip"
	grip.position = Vector3(0.1, 0.2, 0.3)
	root.add_child(grip)
	_box(root, "spout", Vector3(0.05, 0.05, 0.05), Vector3(0, 1.3, 0.2))
	_plane(root, "surface_2", Vector2(0.6, 0.4), Vector3(0, 1.0, 0))
	_plane(root, "surface_1", Vector2(0.6, 0.2), Vector3(0, 0.5, 0.1))   # front half only
	_box(root, "fill", Vector3(0.7, 1.1, 0.4), Vector3(0, 0.6, 0))
	var door := _box(root, "door_1", Vector3(0.38, 1.1, 0.02), Vector3(-0.2, 0.6, 0.26))
	_box(door, "handle_1", Vector3(0.02, 0.1, 0.02), Vector3(0.15, 0, 0.02))
	_box(root, "body-convcolonly", Vector3(0.8, 1.2, 0.5), Vector3(0, 0.6, 0))
	return scene_glb(root)


## A 1.7 m monster: body and head, and (with hits) hit regions for the head, both legs (two pieces of one
## region), the left arm, a tail its JSON doesn't list and one with a bad name.
static func ghoul_glb(hits := true) -> PackedByteArray:
	var root := Node3D.new()
	root.name = "ghoul"
	_box(root, "body", Vector3(0.5, 1.4, 0.3), Vector3(0, 0.7, 0))
	_box(root, "head", Vector3(0.25, 0.3, 0.25), Vector3(0, 1.55, 0.02))
	if hits:
		_box(root, "hit_head", Vector3(0.26, 0.3, 0.26), Vector3(0, 1.55, 0.02))
		_box(root, "hit_leg_1", Vector3(0.2, 0.8, 0.2), Vector3(-0.12, 0.4, 0))
		_box(root, "hit_leg_2", Vector3(0.2, 0.8, 0.2), Vector3(0.12, 0.4, 0))
		_box(root, "hit_arm_l", Vector3(0.1, 0.6, 0.1), Vector3(0.3, 1.0, 0))
		_box(root, "hit_tail", Vector3(0.1, 0.1, 0.4), Vector3(0, 0.6, -0.3))
		_box(root, "hit_Bad", Vector3(0.1, 0.1, 0.1), Vector3(0, 1.2, 0))
	return scene_glb(root)


## A .glb of a node tree (freed afterwards), written by GLTFDocument.
static func scene_glb(root: Node3D) -> PackedByteArray:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(root, state)
	var out := doc.generate_buffer(state)
	root.free()
	return out


## The smallest model that loads: one triangle (u16 indices) on a node of the scene, [glTF JSON, BIN].
## verts: POSITION count (the rest zeros); prims: primitives sharing those accessors.
static func tri_model(verts := 3, prims := 1) -> Array:
	var bin := PackedByteArray()
	bin.resize(verts * 12 + 8)
	var corners := [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
	for k in corners.size():
		bin.encode_float(4 * k, corners[k])
	bin.encode_u16(verts * 12 + 2, 1)
	bin.encode_u16(verts * 12 + 4, 2)
	var list: Array = []
	for i in prims:
		list.append({"attributes": {"POSITION": 0}, "indices": 1})
	var json := {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
			"nodes": [{"name": "body", "mesh": 0}], "meshes": [{"primitives": list}],
			"accessors": [{"bufferView": 0, "componentType": 5126, "count": verts, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]},
				{"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
			"bufferViews": [{"buffer": 0, "byteLength": verts * 12}, {"buffer": 0, "byteOffset": verts * 12, "byteLength": 6}],
			"buffers": [{"byteLength": bin.size()}]}
	return [json, bin]


## Sets JSON fields by path ("meshes/0/primitives/0/mode": 0); null erases a field, a list index one past
## the end appends.
static func patch(json: Dictionary, fields: Dictionary) -> void:
	for path: String in fields:
		var keys := path.split("/")
		var at: Variant = json
		for k in keys.size() - 1:
			at = at[keys[k].to_int()] if at is Array else at[keys[k]]
		var last := keys[keys.size() - 1]
		var value: Variant = fields[path]
		if at is Array:
			if last.to_int() == (at as Array).size():
				(at as Array).append(value)
			else:
				at[last.to_int()] = value
		elif value == null:
			(at as Dictionary).erase(last)
		else:
			at[last] = value


## The one-triangle model as a .glb, JSON fields patched, optionally with another BIN chunk.
static func tri_glb(fields := {}, bin := PackedByteArray(), verts := 3, prims := 1) -> PackedByteArray:
	var t := tri_model(verts, prims)
	patch(t[0], fields)
	return glb_of(t[0], t[1] if bin.is_empty() else bin)


static func _box(parent: Node, name: String, size: Vector3, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = pos
	parent.add_child(mi)
	return mi


static func _plane(parent: Node, name: String, size: Vector2, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.name = name
	var m := PlaneMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = pos
	parent.add_child(mi)


## A .glb from a glTF JSON (a Dictionary or JSON text) and a binary chunk (for hostile files).
static func glb_of(json: Variant, bin := PackedByteArray()) -> PackedByteArray:
	var text: String = json if json is String else JSON.stringify(json)
	var j := text.to_utf8_buffer()
	while j.size() % 4 != 0:
		j.append(0x20)
	var b := bin.duplicate()
	while b.size() % 4 != 0:
		b.append(0)
	var out := PackedByteArray()
	out.resize(20)
	out.encode_u32(0, 0x46546C67)
	out.encode_u32(4, 2)
	out.encode_u32(12, j.size())
	out.encode_u32(16, 0x4E4F534A)
	out.append_array(j)
	if not b.is_empty():
		var h := PackedByteArray()
		h.resize(8)
		h.encode_u32(0, b.size())
		h.encode_u32(4, 0x004E4942)
		out.append_array(h)
		out.append_array(b)
	out.encode_u32(8, out.size())
	return out


func _lib() -> ModelLibrary:
	var lib := ModelLibrary.new()
	lib.root = _dir.path_join("models")
	return lib


func _test_markers() -> void:
	var lib := _lib()
	var m := lib.get_model("furniture/cupboard.glb")
	_check.call(m != null, "a .glb built with GLTFDocument loads " + str(lib.warnings))
	if m == null:
		return
	_check.call(m.parts.size() == 3, "drawn: body, door, handle; not the spout box, shelves, fill or collider (%d)" % m.parts.size())
	_check.call(m.marker("grip").origin.is_equal_approx(Vector3(0.1, 0.2, 0.3)) and m.has_marker("spout"), "point markers: grip, spout")
	var door: int = m.marker_parts.get("door_1", -1)
	var handle: int = m.marker_parts.get("handle_1", -1)
	_check.call(door >= 0 and handle >= 0 and door != handle, "door_1 and handle_1 are moving parts")
	_check.call(m.marker("handle_1").origin.is_equal_approx(Vector3(-0.05, 0.6, 0.28)), "a child marker is in model space")
	_check.call(m.numbered("surface") == PackedStringArray(["surface_1", "surface_2"]) and m.surfaces.size() == 2, "surfaces in order of N")
	var s1: Array = m.surfaces[0]
	var s2: Array = m.surfaces[1]
	_check.call(is_equal_approx(((s1[0] as Transform3D) * Vector3(0, s1[2], 0)).y, 0.5)
			and is_equal_approx(((s2[0] as Transform3D) * Vector3(0, s2[2], 0)).y, 1.0)
			and (s2[1] as Rect2).size.is_equal_approx(Vector2(0.6, 0.4)), "surface heights and sizes")
	_check.call(not m.fill.is_empty() and m.colliders.size() == 1 and m.colliders[0][0] is Mesh,
			"fill volume kept hidden, -convcolonly kept as a collider mesh")
	_check.call(m.triangles == 76 and is_equal_approx(m.aabb.size.y, 1.2), "triangles %d, bounds %s" % [m.triangles, m.aabb])
	_check.call(lib.get_model("furniture/cupboard.glb") == m, "cached per path")
	_check.call(ModelLibrary.marker_kind("door_12") == ModelLibrary.Marker.PART and ModelLibrary.marker_kind("door_0") == ModelLibrary.Marker.NONE
			and ModelLibrary.marker_kind("surface_+1") == ModelLibrary.Marker.NONE and ModelLibrary.marker_kind("burner_2") == ModelLibrary.Marker.POINT
			and ModelLibrary.marker_kind("grip_2") == ModelLibrary.Marker.POINT and ModelLibrary.marker_kind("door_100") == ModelLibrary.Marker.NONE,
			"marker names: numbered 1-99 only")


## Registry `material` tints a model: a cached variant with copied meshes and materials, the original untouched.
func _test_tint() -> void:
	var lib := _lib()
	var path := "furniture/cupboard.glb"
	var m := lib.get_model(path)
	if m == null:
		_check.call(false, "tint: the cupboard loads")
		return
	var before := []   # [material, albedo colour] of each part's surfaces before tinting
	for p: Array in m.parts:
		var mesh := p[0] as ArrayMesh
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s)
			before.append([mat, (mat as BaseMaterial3D).albedo_color if mat is BaseMaterial3D else Color()])
	var t := lib.get_tinted(path, "brick")
	_check.call(t != null and t != m and t.tint == "brick" and lib.get_tinted(path, "brick") == t
			and lib.get_tinted(path, "wood_dark") != t, "a tinted variant is its own model, cached per path and material")
	_check.call(lib.get_tinted(path, "") == m and lib.get_tinted(path, "no_such_material") == m
			and lib.get_tinted("furniture/missing.glb", "brick") == null, "no or unknown material: the model as made; missing: null")
	if t == null or t == m:
		return
	_check.call(t.parts.size() == m.parts.size() and t.markers == m.markers and t.surfaces == m.surfaces
			and t.marker_parts == m.marker_parts and t.aabb == m.aabb, "the variant keeps the model's parts, markers and surfaces")
	var factor := Color.WHITE.lerp(CddaPalette.material("brick"), ModelLibrary.TINT)
	var k := 0
	var same_data := true
	var tinted_ok := true
	var textured := false
	for i in m.parts.size():
		var om := m.parts[i][0] as ArrayMesh
		var tm := t.parts[i][0] as ArrayMesh
		same_data = same_data and tm != om and tm.get_surface_count() == om.get_surface_count() \
				and (t.parts[i][1] as Transform3D) == (m.parts[i][1] as Transform3D)
		for s in mini(om.get_surface_count(), tm.get_surface_count()):
			same_data = same_data and tm.surface_get_array_len(s) == om.surface_get_array_len(s)
			var a := om.surface_get_material(s) as BaseMaterial3D
			var b := tm.surface_get_material(s) as BaseMaterial3D
			tinted_ok = tinted_ok and a != null and b != null and a != b and b.albedo_texture == a.albedo_texture \
					and b.albedo_color.is_equal_approx(a.albedo_color * factor)
			textured = textured or b.albedo_texture != null
	_check.call(same_data, "the variant's meshes are copies with the same surfaces and vertices")
	_check.call(tinted_ok and textured, "its materials are copies, albedo * lerp(white, brick, %.1f), textures kept" % ModelLibrary.TINT)
	var untouched := true
	for p: Array in m.parts:
		var mesh := p[0] as ArrayMesh
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s)
			untouched = untouched and k < before.size() and mat == before[k][0] \
					and (not mat is BaseMaterial3D or (mat as BaseMaterial3D).albedo_color == before[k][1])
			k += 1
	_check.call(untouched and k == before.size(), "the original model's materials are untouched")
	var capped := _lib()
	capped.max_tinted = 1
	var first := capped.get_tinted(path, "brick")
	_check.call(first != null and first.tint == "brick" and capped.get_tinted(path, "wood").tint.is_empty()
			and capped.get_tinted(path, "brick") == first and capped.warnings.size() == 1 and capped.warnings[0].contains("tinted"),
			"tinted variants are capped: past the cap, the model as made, with one warning " + str(capped.warnings))
	var mapped := not m.sources.is_empty()
	for p: Array in m.parts:
		mapped = mapped and m.sources.get(p[0]) is ImporterMesh
	_check.call(mapped, "tinted variants are made from the importer's copies of every drawn mesh")
	var busy := _lib()
	busy.get_model(path)
	var out: Array = [null]
	var task := WorkerThreadPool.add_task(func() -> void: out[0] = busy.get_tinted(path, "wood_dark"))
	var spins := 0
	while not WorkerThreadPool.is_task_completed(task) and spins < 3000:
		busy.get_warnings()
		busy.get_model(path)
		busy.get_tinted(path, "")
		spins += 1
		OS.delay_usec(500)
	var finished := WorkerThreadPool.is_task_completed(task)
	if finished:
		WorkerThreadPool.wait_for_task_completion(task)
	_check.call(finished and out[0] != null and (out[0] as ModelLibrary.Model).tint == "wood_dark",
			"a worker tints while the main thread keeps asking the library (no wait on each other)")
	var budget := _lib()
	budget.max_total_triangles = m.triangles
	_check.call(budget.get_model(path) != null and budget.get_tinted(path, "brick").tint.is_empty()
			and budget.get_model("furniture/cupboard_2.glb") == null and budget.warnings.size() == 2
			and budget.warnings[0].contains("mesh budget"), "mesh budget: past it, models aren't kept and variants are untinted " + str(budget.warnings))


func _test_caps(glb: PackedByteArray) -> void:
	for c: Array in [["max_triangles", 50, "triangles"], ["max_markers", 4, "markers"], ["max_nodes", 5, "nodes"],
			["max_file_bytes", 100, "larger than"], ["max_parts", 2, "drawn parts"]]:
		var lib := _lib()
		lib.set(c[0], c[1])
		_check.call(lib.get_model("furniture/cupboard.glb") == null and lib.warnings.size() == 1 and lib.warnings[0].contains(c[2]),
				"cap %s: skipped with a warning (%s)" % [c[0], ",".join(lib.warnings)])
	_check.call(_lib().check_glb(glb).is_empty(), "the cupboard passes the checks (embedded PNG texture)")


func _test_hostile(glb: PackedByteArray) -> void:
	var asset := {"version": "2.0"}
	var png := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
			0, 0, 0x4E, 0x20, 0, 0, 0x4E, 0x20, 8, 6, 0, 0, 0, 0, 0, 0, 0])   # 20000 x 20000
	var jpg := PackedByteArray([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0xFF, 0xC0, 0, 17, 8, 0x13, 0x88, 0, 16, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0])   # 5000 high
	var img := func(bytes: PackedByteArray, mime: String) -> PackedByteArray:
		return glb_of({"asset": asset, "buffers": [{"byteLength": bytes.size()}],
				"bufferViews": [{"buffer": 0, "byteLength": bytes.size()}],
				"images": [{"bufferView": 0, "mimeType": mime}]}, bytes)
	var garbage := PackedByteArray()
	for i in 200:
		garbage.append((i * 37 + 11) % 256)
	# JPEG headers whose first frame can't be found by walking the segments the way decoders do
	var tail := PackedByteArray([0xFF, 0xDB, 0, 4, 0, 0, 0xFF, 0xC4, 0, 4, 0, 0, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 0x3F, 0,
			0, 0, 0, 0, 0xFF, 0xD9])
	var stuffed := PackedByteArray([0xFF, 0xD8, 0xFF, 0x00, 0x00, 0x14, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x40, 0x00, 0x40, 0x00,
			0x01, 0x01, 0x11, 0x00, 0xFF, 0xE0, 0x00, 0x12, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x08, 0x00, 0x08, 0x01, 0x01,
			0x11, 0x00, 0, 0, 0]) + tail
	var scan_first := PackedByteArray([0xFF, 0xD8, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 0x3F, 0, 0xFF, 0xC0, 0, 11, 8, 0, 8, 0, 8,
			1, 1, 0x11, 0]) + tail
	var short_len := PackedByteArray([0xFF, 0xD8, 0xFF, 0xE0, 0, 1, 0xFF, 0xC0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0]) + tail
	var two_soi := PackedByteArray([0xFF, 0xD8, 0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0]) + tail
	var eoi_first := PackedByteArray([0xFF, 0xD8, 0xFF, 0xD9, 0xFF, 0xC0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0]) + tail
	var plain_jpg := PackedByteArray([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF,
			0xFF, 0xC0, 0, 11, 8, 0, 16, 0, 32, 1, 1, 0x11, 0]) + tail
	var chain: Array = []   # no cycle, one level deeper than MAX_DEPTH
	for i in ModelLibrary.MAX_DEPTH + 2:
		chain.append({"children": [i + 1]} if i < ModelLibrary.MAX_DEPTH + 1 else {})
	var walk_ok := ModelLibrary._image_size(plain_jpg, 0, plain_jpg.size()) == Vector2i(32, 16)
	for bad: PackedByteArray in [stuffed, scan_first, short_len, two_soi, eoi_first]:
		walk_ok = walk_ok and ModelLibrary._image_size(bad, 0, bad.size()) == Vector2i(-1, -1)
	_check.call(walk_ok, "JPEG size: read from the first frame of a plain header; odd marker sequences are unreadable")
	var cases := [
		["image without mimeType", glb_of({"asset": asset, "buffers": [{"byteLength": png.size()}],
				"bufferViews": [{"buffer": 0, "byteLength": png.size()}], "images": [{"bufferView": 0}]}, png), "mimeType"],
		["JPEG stuffed byte before the frame", img.call(stuffed, "image/jpeg"), "bad image"],
		["JPEG scan before the frame", img.call(scan_first, "image/jpeg"), "bad image"],
		["JPEG segment length under 2", img.call(short_len, "image/jpeg"), "bad image"],
		["nodes nested too deep", glb_of({"asset": asset, "nodes": chain}), "deeper than"],
		["JSON chunk over 4 MiB", glb_of({"asset": asset, "extras": {"pad": "x".repeat(ModelLibrary.MAX_JSON_BYTES)}}), "JSON chunk"],
		["two buffers", glb_of({"asset": asset, "buffers": [{"byteLength": 4}, {"byteLength": 4}]}, PackedByteArray([1, 2, 3, 4])), "buffers"],
		["fractional count", glb_of({"asset": asset, "accessors": [{"count": 2.5}]}), "elements"],
		["glTF JSON not ASCII", glb_of('{"asset": {"version": "2.0"}, "nodes": [{"name": "caf\u00e9"}]}'), "ASCII"],
		["garbage", garbage, "not a .glb"],
		["truncated", glb.slice(0, glb.size() - 8), "length field"],
		["external buffer", glb_of({"asset": asset, "buffers": [{"uri": "../../secret.bin", "byteLength": 4}]}), "buffers must be"],
		["external image", glb_of({"asset": asset, "images": [{"uri": "C:/Windows/win.ini"}]}), "embedded"],
		["node cycle", glb_of({"asset": asset, "nodes": [{"children": [1]}, {"children": [0]}]}), "cycle"],
		["two parents", glb_of({"asset": asset, "nodes": [{"children": [2]}, {"children": [2]}, {}]}), "children"],
		["huge PNG", img.call(png, "image/png"), "larger than"],
		["huge JPEG", img.call(jpg, "image/jpeg"), "larger than"],
		["GIF", img.call("GIF89a and some more bytes!".to_utf8_buffer(), "image/gif"), "PNG or JPEG"],
		["view outside", glb_of({"asset": asset, "buffers": [{"byteLength": 4}], "bufferViews": [{"buffer": 0, "byteOffset": 2, "byteLength": 8}]},
				PackedByteArray([1, 2, 3, 4])), "outside"],
		["required extension", glb_of({"asset": asset, "extensionsRequired": ["KHR_draco_mesh_compression"]}), "extension"],
		["accessor count", glb_of({"asset": asset, "accessors": [{"count": 1e9}]}), "elements"],
		["no mesh", glb_of({"asset": asset, "nodes": [{"name": "grip"}], "scenes": [{"nodes": [0]}]}), "no visible mesh"],
	]
	for c: Array in cases:
		_write("models/furniture/bad.glb", c[1])
		var lib := _lib()
		_check.call(lib.get_model("furniture/bad.glb") == null and lib.warnings.size() == 1 and lib.warnings[0].contains(c[2]),
				"hostile file (%s): skipped with a warning %s" % [c[0], lib.warnings])
	var lib := _lib()
	for p: String in ["../registry/x.glb", "/furniture/cupboard.glb", "C:/x.glb", "furniture\\cupboard.glb",
			"furniture/cupboard.gltf", "furniture//cupboard.glb", "furniture/./cupboard.glb", "res://x.glb"]:
		_check.call(lib.resolve(p).is_empty() and lib.get_model(p) == null, "path refused: " + p)
	_check.call(lib.get_model("furniture/missing.glb") == null and lib.warnings[-1].contains("missing"), "missing file: a warning")
	for p: String in ["con.glb", "furniture/nul.glb", "furniture/Aux.x.glb", "furniture./cupboard.glb"]:
		_check.call(lib.resolve(p).is_empty(), "path refused: " + p)


func _test_colliders() -> void:
	var m := _lib().get_model("furniture/cupboard.glb")
	if m == null:
		return
	var mesh: Variant = m.colliders[0][0] if m.colliders.size() == 1 else null
	var shape: ConvexPolygonShape3D = ModelLibrary.collider_shape(mesh) if mesh is Mesh else null
	_check.call(shape != null and shape.points.size() == 8, "the collider's convex shape is built on demand (%d points)"
			% (shape.points.size() if shape else -1))
	var sphere := SphereMesh.new()
	sphere.radial_segments = 64
	sphere.rings = 32
	var hull := ModelLibrary.collider_shape(sphere)
	_check.call(hull != null and hull.points.size() > 8 and hull.points.size() <= ModelLibrary.MAX_HULL_POINTS,
			"a collider hull starts from at most %d points (%d)" % [ModelLibrary.MAX_HULL_POINTS, hull.points.size() if hull else -1])


## C6: a see-through part of a model is drawn under the light pass (darkened at night), its tinted copy too;
## an opaque one keeps its place.
func _test_see_through() -> void:
	var prio := func(m: ModelLibrary.Model) -> int:
		if m == null or m.parts.is_empty():
			return 1 << 20
		var mat := (m.parts[0][0] as Mesh).surface_get_material(0)
		return mat.render_priority if mat != null else 1 << 20
	_write("models/furniture/tri.glb", tri_glb({"materials": [{"alphaMode": "BLEND",
			"pbrMetallicRoughness": {"baseColorFactor": [0.5, 0.7, 0.9, 0.4]}}], "meshes/0/primitives/0/material": 0}))
	var lib := _lib()
	var glass := lib.get_model("furniture/tri.glb")
	_check.call(prio.call(glass) == WorldLighting.UNDER_PRIORITY
			and prio.call(lib.get_tinted("furniture/tri.glb", "brick")) == WorldLighting.UNDER_PRIORITY,
			"a see-through model part is drawn under the light pass, tinted too (%s)" % prio.call(glass))
	_write("models/furniture/tri.glb", tri_glb({"materials": [{"alphaMode": "MASK"}], "meshes/0/primitives/0/material": 0}))
	_check.call(prio.call(_lib().get_model("furniture/tri.glb")) == 0, "a cut-out (MASK) part stays in the opaque pass")
	var plain := StandardMaterial3D.new()
	_check.call(not ModelLibrary.under_light(plain) and plain.render_priority == 0 and not ModelLibrary.under_light(null),
			"an opaque material keeps its place")
	_write("models/furniture/tri.glb", tri_glb())


## One small .glb per rule of the strict checks; the one-triangle model itself loads.
func _test_strict() -> void:
	_write("models/furniture/tri.glb", tri_glb())
	var lib := _lib()
	_check.call(lib.get_model("furniture/tri.glb") != null, "the one-triangle model loads " + str(lib.warnings))
	_write("models/furniture/tri.glb", tri_glb({"extensionsUsed": ["KHR_materials_unlit"], "materials": [{"extensions": {"KHR_materials_unlit": {}}}],
			"meshes/0/primitives/0/material": 0, "nodes/0/extras": {"extensions": {"anything": 1}}}))
	lib = _lib()
	_check.call(lib.get_model("furniture/tri.glb") != null, "known extensions and extras still load " + str(lib.warnings))
	_test_see_through()
	var asset := {"version": "2.0"}
	var png := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
			0, 0, 8, 0, 0, 0, 8, 0, 8, 6, 0, 0, 0, 0, 0, 0, 0])   # 2048 x 2048
	var images := func(n: int, mime: String) -> PackedByteArray:
		var list: Array = []
		for i in n:
			list.append({"bufferView": 0, "mimeType": mime})
		return glb_of({"asset": asset, "buffers": [{"byteLength": png.size()}],
				"bufferViews": [{"buffer": 0, "byteLength": png.size()}], "images": list}, png)
	var info := {}
	_check.call(_lib().check_glb(images.call(2, "image/png"), info).is_empty() and info.get("pixels") == 2 * 2048 * 2048,
			"two 2048 px images are within the pixel cap")
	var past: PackedByteArray = tri_model()[1]
	past.encode_u16(40, 3)
	var t := tri_model()
	patch(t[0], {"nodes/0/translation": [7777.5, 0, 0]})
	var not_finite := glb_of(JSON.stringify(t[0]).replace("7777.5", "1e999"), t[1])
	var big := Node3D.new()
	big.name = "big"
	_box(big, "body", Vector3(30, 1, 1), Vector3(0, 0.5, 0))
	var view := "bufferViews/0/byteStride"
	var cases := [
		["points mode", tri_glb({"meshes/0/primitives/0/mode": 0}), "triangle"],
		["strip mode", tri_glb({"meshes/0/primitives/0/mode": 5}), "triangle"],
		["no POSITION", tri_glb({"meshes/0/primitives/0/attributes": {"NORMAL": 0}}), "POSITION"],
		["attribute counts differ", tri_glb({"accessors/2": {"bufferView": 0, "componentType": 5126, "count": 2, "type": "VEC3"},
				"meshes/0/primitives/0/attributes/NORMAL": 2}), "count"],
		["attribute type", tri_glb({"meshes/0/primitives/0/attributes/TEXCOORD_0": 0}), "attribute"],
		["index count", tri_glb({"accessors/1/count": 2}), "multiple of 3"],
		["index past the vertices", tri_glb({}, past), "past its vertices"],
		["vertex count", tri_glb({"meshes/0/primitives/0/indices": null, "accessors/0/count": 2}), "multiple of 3"],
		["vertices in a primitive", tri_glb({}, PackedByteArray(), 65537), "65536 vertices"],
		["vertices in all meshes", tri_glb({}, PackedByteArray(), 65536, 4), "vertices in all"],
		["animations", tri_glb({"animations": [{"channels": [], "samplers": []}]}), "animations"],
		["skins", tri_glb({"skins": [{"joints": [0]}]}), "skins"],
		["cameras", tri_glb({"cameras": [{"type": "perspective", "perspective": {"yfov": 1.0, "znear": 0.1}}]}), "cameras"],
		["node skin", tri_glb({"nodes/0/skin": 0}), "skins"],
		["node camera", tri_glb({"nodes/0/camera": 0}), "cameras"],
		["morph targets", tri_glb({"meshes/0/primitives/0/targets": [{"POSITION": 0}]}), "morph"],
		["mesh weights", tri_glb({"meshes/0/weights": [0.5]}), "morph"],
		["component type", tri_glb({"accessors/0/componentType": 5124}), "accessor type"],
		["accessor type", tri_glb({"accessors/0/type": "VEC5"}), "accessor type"],
		["accessor past its view", tri_glb({"accessors/0/count": 4}), "past its buffer view"],
		["accessor offset", tri_glb({"accessors/0/byteOffset": -4}), "offset"],
		["accessor offset alignment", tri_glb({"accessors/1/byteOffset": 1}), "offset"],
		["stride under the element", tri_glb({view: 8}), "stride"],
		["stride not a multiple of 4", tri_glb({view: 14}), "stride"],
		["stride over 252", tri_glb({view: 256}), "stride"],
		["sparse accessor", tri_glb({"accessors/0/sparse": {"count": 1}}), "sparse"],
		["accessor without a view", tri_glb({"accessors/0/bufferView": null}), "buffer view"],
		["view index", tri_glb({"accessors/0/bufferView": 5}), "buffer view"],
		["view of a missing buffer", tri_glb({"bufferViews/0/buffer": 1}), "buffer view"],
		["scene index", tri_glb({"scene": 3}), "scene"],
		["scene node twice", tri_glb({"scenes/0/nodes": [0, 0]}), "scene"],
		["scene node with a parent", tri_glb({"nodes/1": {"name": "group", "children": [0]}, "scenes/0/nodes": [0, 1]}), "scene"],
		["node mesh", tri_glb({"nodes/0/mesh": 4}), "node mesh"],
		["material texture", tri_glb({"materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 2}}}]}), "material texture"],
		["normal texture", tri_glb({"materials": [{"normalTexture": {"index": 0}}]}), "material texture"],
		["texture image", tri_glb({"textures": [{"source": 4}]}), "texture image"],
		["texture sampler", tri_glb({"textures": [{"sampler": 1}]}), "sampler"],
		["sampler value", tri_glb({"samplers": [{"magFilter": 1}]}), "sampler"],
		["primitive material", tri_glb({"meshes/0/primitives/0/material": 3}), "material"],
		["extension in use", tri_glb({"extensionsUsed": ["KHR_draco_mesh_compression"]}), "extension"],
		["node extension", tri_glb({"nodes/0/extensions": {"OMI_physics_body": {}}}), "OMI_physics_body"],
		["material extension", tri_glb({"materials": [{"extensions": {"KHR_materials_clearcoat": {}}}]}), "extension"],
		["texture info extension", tri_glb({"textures": [{}], "materials": [{"normalTexture": {"index": 0, "extensions": {"EXT_example": {}}}}]}), "extension"],
		["image pixels", images.call(3, "image/png"), "pixels"],
		["image mimeType", images.call(1, "image/jpeg"), "PNG or JPEG"],
		["node transform size", tri_glb({"nodes/0/translation": [1, 2]}), "node transform"],
		["node transform number", not_finite, "node transform"],
		["model size", scene_glb(big), "20 m"],
		["rotation not a unit quaternion", tri_glb({"nodes/0/rotation": [0, 0, 0, 0]}), "rotation"],
		["rotation scaled", tri_glb({"nodes/0/rotation": [0, 0, 0, 2]}), "rotation"],
		["flat matrix", tri_glb({"nodes/0/matrix": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]}), "flat matrix"],
		["scene without nodes", tri_glb({"scenes/0/nodes": null}), "scene"],
		["texture without a source", tri_glb({"textures": [{}]}), "texture image"],
		["2-byte attribute without a stride", tri_glb({"accessors/2": {"bufferView": 0, "componentType": 5121, "normalized": true,
				"count": 3, "type": "VEC2"}, "meshes/0/primitives/0/attributes/TEXCOORD_0": 2}), "byteStride"],
		["strided index view", tri_glb({"bufferViews/1/byteStride": 4, "accessors/1/count": 1}), "indices"],
		["primitives in a mesh", tri_glb({}, PackedByteArray(), 3, ModelLibrary.MAX_MESH_PRIMITIVES + 1), "primitives"],
		["surfaces drawn", tri_glb({"nodes/1": {"mesh": 0}, "nodes/2": {"mesh": 0}, "nodes/3": {"mesh": 0},
				"nodes/4": {"mesh": 0}}, PackedByteArray(), 3, ModelLibrary.MAX_MESH_PRIMITIVES), "surfaces drawn"],
	]
	for c: Array in cases:
		_write("models/furniture/bad.glb", c[1])
		lib = _lib()
		_check.call(lib.get_model("furniture/bad.glb") == null and lib.warnings.size() == 1 and lib.warnings[0].contains(c[2]),
				"rejects: %s %s" % [c[0], lib.warnings])
	var root := Node3D.new()
	_box(root, "body", Vector3.ONE, Vector3(NAN, 0, 0))
	var why := _lib()._read(root, ModelLibrary.Model.new())
	root.free()
	_check.call(why.contains("finite"), "rejects: transform not finite (%s)" % why)


func _test_index_max() -> void:
	var u16 := func(values: Array) -> int:
		var b := PackedByteArray()
		b.resize(2 * values.size())
		for i in values.size():
			b.encode_u16(2 * i, values[i])
		return ModelLibrary._index_max(b, 0, values.size(), 5123)
	var u32 := func(values: Array) -> int:
		var b := PackedByteArray()
		b.resize(4 * values.size())
		for i in values.size():
			b.encode_u32(4 * i, values[i])
		return ModelLibrary._index_max(b, 0, values.size(), 5125)
	var got := [u16.call([0, 1, 2]), u16.call([5, 1, 2, 0, 7, 3]), u16.call([0, 40000, 1]), u16.call([65535, 0, 0]),
			u16.call([3, 0, 1, 2, 40001, 5, 6, 7, 9]), u16.call([1, 2, 3, 4, 5, 32768]),
			ModelLibrary._index_max(PackedByteArray([3, 9, 1]), 0, 3, 5121), u32.call([1, 5, 2]), u32.call([1, 2, 0x80000000])]
	_check.call(got == [2, 7, 40000, 65535, 40001, 32768, 9, 5, 0x7FFFFFFF], "largest index of u8, u16 and u32 lists " + str(got))


func _test_cache(glb: PackedByteArray) -> void:
	_write("models/furniture/cupboard_2.glb", glb)
	_write("models/furniture/not_a_model.glb", "not a model".to_utf8_buffer())
	var lib := _lib()
	var m := lib.get_model("furniture/cupboard.glb")
	_check.call(m != null and lib.get_model("FURNITURE/Cupboard.GLB") == m and lib.warnings.is_empty(), "cache keys are case-folded")
	lib = _lib()
	lib.max_models = 1
	var failed := lib.get_model("furniture/not_a_model.glb") == null and lib.get_model("furniture/missing.glb") == null
	var first := lib.get_model("furniture/cupboard.glb")
	_check.call(failed and first != null and lib.get_model("furniture/cupboard_2.glb") == null and lib.warnings[-1].contains("more than 1 models"),
			"failed loads don't count toward the model cap " + str(lib.warnings))
	lib = _lib()
	lib.max_failed = 1
	lib.get_model("furniture/not_a_model.glb")
	lib.get_model("furniture/missing.glb")
	lib.get_model("furniture/missing_2.glb")
	_check.call(lib.warnings.size() == 2 and lib.warnings[1].contains("failed") and lib.get_model("furniture/cupboard.glb") == null,
			"failed loads are capped " + str(lib.warnings))
	lib = _lib()
	lib.max_image_bytes = 300   # the cupboard's 8 x 8 texture is 256 bytes decoded
	_check.call(lib.get_model("furniture/cupboard.glb") != null and lib.get_model("furniture/cupboard_2.glb") == null
			and lib.warnings.size() == 1 and lib.warnings[0].contains("image memory"), "image memory budget across models " + str(lib.warnings))
	# Fake loads: Godot's headless renderer (all client tests) doesn't take textures or meshes from two threads at
	# once, so two real .glb loads racing here print renderer errors now and then. The cache is what's checked.
	var racing := SlowLoads.new()
	var got: Array = [null]
	var task := WorkerThreadPool.add_task(func() -> void: got[0] = racing.get_model("furniture/cupboard.glb"))
	var here := racing.get_model("furniture/cupboard.glb")
	WorkerThreadPool.wait_for_task_completion(task)
	_check.call(here != null and got[0] == here, "one model for two threads asking at once")
	lib = _lib()
	lib.get_model("bad\u0007name\n" + "x".repeat(400) + ".glb")
	var w := lib.warnings[0] if lib.warnings.size() == 1 else ""
	var plain := not w.is_empty()
	for c in w:
		plain = plain and c.unicode_at(0) >= 0x20
	_check.call(plain and w.length() < 160, "warnings drop control characters and cap file text: " + w.left(40))


## A models folder path through a link or junction is refused (skipped where no link can be made).
func _test_links(glb: PackedByteArray) -> void:
	var target := _dir.path_join("registry")
	var link := _dir.path_join("models/linked")
	_write("registry/cupboard.glb", glb)
	var da := DirAccess.open(_dir)
	if da.create_link(target, link) != OK and OS.get_name() == "Windows":
		OS.execute("cmd.exe", ["/c", "mklink", "/J", link.replace("/", "\\"), target.replace("/", "\\")])
	if not DirAccess.dir_exists_absolute(link):
		print("  (skipped: no link could be made here)")
	else:
		var lib := _lib()
		_check.call(lib.resolve("linked/cupboard.glb").is_empty() and lib.get_model("linked/cupboard.glb") == null
				and lib.warnings.size() == 1 and lib.warnings[0].contains("inside"), "a path through a link or junction is refused")
		DirAccess.remove_absolute(link)
	DirAccess.remove_absolute(target.path_join("cupboard.glb"))


func _test_props(data: Variant, tables: IdTables, scene: Callable, repo: Callable) -> void:
	_write("models/furniture/garbage.glb", "not a model".to_utf8_buffer())
	var entries := [
		{"type": "fp3d_model", "id": "f_cupboard", "kind": "furniture", "model": "furniture/cupboard.glb", "placeholder": "counter"},
		{"type": "fp3d_model", "id": "f_dresser", "kind": "furniture", "model": "furniture/garbage.glb", "placeholder": "dresser"},
		{"type": "fp3d_model", "id": "f_chair", "kind": "furniture", "model": "furniture/missing.glb"},
		{"type": "fp3d_model", "id": "101_carpentry", "kind": "item", "model": "furniture/cupboard.glb", "scale": 0.25},
		{"type": "fp3d_model", "id": "f_counter", "kind": "furniture", "model": "furniture/cupboard.glb", "material": "wood_dark"},
	]
	_write("registry/test.json", JSON.stringify(entries).to_utf8_buffer())
	var reg := AssetRegistry.new()
	reg.models.root = _dir.path_join("models")
	reg.load_dir(repo.call("assets/registry"))
	reg.load_dir(_dir.path_join("registry"))   # later files override: these entries win
	var terrain := TerrainCatalog.new()
	terrain.registry = reg
	terrain.set_tables(tables)
	var cat := PropCatalog.new(reg)
	cat.set_tables(tables)
	var S := AssetRegistry.Step
	var furn := func(id: String) -> PropCatalog.Prop: return cat.furniture(tables.index_of("furn", id))
	var cupboard: PropCatalog.Prop = furn.call("f_cupboard")
	_check.call(cupboard.model != null and cupboard.step == S.EXACT and cupboard.shape == "counter", "a loadable model is art (step 1)")
	var dresser: PropCatalog.Prop = furn.call("f_dresser")
	_check.call(dresser.model == null and dresser.shape == "dresser" and dresser.step == S.EXACT
			and "\n".join(terrain.warnings).contains("garbage.glb"), "a broken model falls back to the placeholder, with a warning")
	var chair: PropCatalog.Prop = furn.call("f_chair")
	_check.call(chair.model == null and chair.step != S.EXACT and not chair.shape.is_empty(),
			"a model-only entry whose file is missing goes on down the chain (step %d, %s)" % [chair.step, chair.shape])
	var book_i := tables.index_of("itype", "101_carpentry")
	_check.call(cat.item(book_i).model != null and is_equal_approx(cat.item(book_i).scale, 0.25), "item models keep their real size (registry scale only)")
	var counter: PropCatalog.Prop = furn.call("f_counter")
	_check.call(cupboard.model == reg.models.get_model("furniture/cupboard.glb") and counter.model != null
			and counter.model == reg.models.get_tinted("furniture/cupboard.glb", "wood_dark") and counter.model != cupboard.model,
			"an entry with model and material draws the tinted variant; without material, the model as made")

	var at := func(x: int, y: int) -> int: return y * 12 + x
	var snap: Snapshot = scene.call(data, tables, {}, {at.call(5, 5): "f_cupboard", at.call(7, 5): "f_dresser"},
			[[at.call(5, 5), 3, [book_i, book_i, 0, 0]], [at.call(7, 5), 1, [book_i, 0, 0, 0]]])
	var sm: Snapshot.Submap = null
	for p: Vector3i in snap.submaps:
		if (snap.submaps[p] as Snapshot.Submap).furn[at.call(5, 5)] == tables.index_of("furn", "f_cupboard"):
			sm = snap.submaps[p]
	terrain.set_snapshot(snap)
	cat.set_snapshot(snap)
	var pm := PropMesher.new(snap, terrain, cat)
	var r := pm.build(sm.pos)
	# The cupboard's door_1 opens (a Grabbable part): the furniture draws the model without it (`still`).
	var xfs: Array = r.models.get(cupboard.model.still, []) if cupboard.model.still != null else []
	_check.call(r.model_props == 5 and xfs.size() == 1 and (r.models.get(cupboard.model, []) as Array).size() == 2
			and r.parts.size() == 4, "model props listed: the cupboard (still, its door a part), two books on it, the placeholder dresser (its three drawers parts) and the book in it (%d)" % r.model_props)
	if xfs.is_empty():
		return
	var base := CddaCoords.sm_to_ms(sm.pos)
	var rng := RandomNumberGenerator.new()
	rng.seed = PropMesher._hash(base + Vector3i(5, 5, 0))
	var d: Vector3i = PropMesher.DIRS[pm.facing(base + Vector3i(5, 5, 0), cupboard, rng)]
	var xf: Transform3D = xfs[0]
	var front := (xf.basis * Vector3.BACK).normalized()
	_check.call(front.is_equal_approx(Vector3(d.x, 0, d.y)), "a model's +z front faces where a shape's -z would")
	var tile := {at.call(5, 5): Transform3D(xf.basis, xf.origin) * PropMesher.MODEL_TURN}
	var on: Array = pm.pile_transforms(sm, base, sm.items.slice(0, Snapshot.PILE_STRIDE), tile)
	var heights := on.map(func(e: Array) -> float: return snappedf((e[0] as Transform3D).origin.y, 0.001))
	_check.call(heights == [0.5, 1.0, 0.5], "items lie on the model's surface_1, surface_2, surface_1 " + str(heights))
	var first: Vector3 = (on[0][0] as Transform3D).origin - xf.origin
	_check.call(first.dot(front) > 0.0 and absf(first.dot(front)) <= 0.21, "surface_1 (front half) turns with the model")
	var in_dresser: Array = pm.pile_transforms(sm, base, sm.items.slice(Snapshot.PILE_STRIDE, 2 * Snapshot.PILE_STRIDE), {})
	_check.call(in_dresser.size() == 1 and int(in_dresser[0][6]) >= 0, "the book in the placeholder dresser lies in a drawer (PropBoxes)")

	var world := WorldView.new()
	world.catalog = terrain
	world.props = cat
	world.set_id_tables(tables)
	world.apply_snapshot(snap)
	var holder := world.node_of(sm.pos).get_node_or_null("models")
	var mms := holder.get_children() if holder else []
	var counts := mms.map(func(n: Node) -> int: return (n as MultiMeshInstance3D).multimesh.instance_count)
	var door_sq := base + Vector3i(5, 5, 0)
	_check.call(counts == [1, 1, 2, 2, 2] and world.prop_counts["models"] >= 3
			and world.parts.has("%d_%d_%d/door_1" % [door_sq.x, door_sq.y, door_sq.z]),
			"the world draws one multimesh per model part, an instance per prop (the cupboard's and the dresser's still bodies; books) " + str(counts))
	world.free()


## Join pieces (`joins`): an L, a T and a cross of counters draw their ends, middles, corner, tee and cross
## as the registry names them, each turned so its joining sides meet its neighbours; a lone counter draws
## the plain model. Bad `joins` refuse the entry.
func _test_joins(data: Variant, tables: IdTables, scene: Callable, repo: Callable) -> void:
	DirAccess.make_dir_recursive_absolute(_dir.path_join("registry_joins"))
	var names := ["single", "end_left", "end_right", "middle", "corner", "tee", "cross"]
	var joins := {}
	for n: String in names:
		_write("models/furniture/c_%s.glb" % n, tri_glb())
		if n != "single":
			joins[n] = "furniture/c_%s.glb" % n
	var one := "furniture/c_single.glb"
	var entries := [
		{"type": "fp3d_model", "id": "f_counter", "kind": "furniture", "model": one, "placeholder": "counter", "joins": joins},
		{"type": "fp3d_model", "id": "x_bad1", "kind": "furniture", "model": one, "joins": {"end": one}},
		{"type": "fp3d_model", "id": "x_bad2", "kind": "furniture", "model": one, "joins": {"middle": "../c.glb"}},
		{"type": "fp3d_model", "id": "x_bad3", "kind": "furniture", "model": one, "joins": {"middle": 5}},
		{"type": "fp3d_model", "id": "x_bad4", "kind": "item", "model": one, "joins": {"middle": one}},
		{"type": "fp3d_model", "id": "x_bad5", "kind": "furniture", "placeholder": "counter", "joins": {"middle": one}},
		{"type": "fp3d_model", "id": "x_bad6", "kind": "furniture", "model": one, "joins": [one]},
	]
	_write("registry_joins/test.json", JSON.stringify(entries).to_utf8_buffer())
	var reg := AssetRegistry.new()
	reg.models.root = _dir.path_join("models")
	reg.load_dir(repo.call("assets/registry"))
	var before := reg.warnings.size()
	reg.load_dir(_dir.path_join("registry_joins"))
	var refused := range(1, 7).all(func(k: int) -> bool:
		return reg.entry("x_bad%d" % k, "furniture") == null and reg.entry("x_bad%d" % k, "item") == null)
	_check.call(refused and reg.warnings.size() - before == 6, "joins: an unknown piece, a bad path, joins on an item or without a model refuse the entry")
	var terrain := TerrainCatalog.new()
	terrain.registry = reg
	terrain.set_tables(tables)
	var cat := PropCatalog.new(reg)
	cat.set_tables(tables)
	_check.call(cat.furniture(tables.index_of("furn", "f_counter")).joins.size() == 6, "joins: the counter has its six pieces")
	var at := func(x: int, y: int) -> int: return y * 12 + x
	# An L, a lone counter, a T (row y 7, stem down at x 3) and a cross centred on (8, 4).
	var counters := [Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2), Vector2i(5, 2), Vector2i(2, 3), Vector2i(2, 4), Vector2i(9, 9),
			Vector2i(2, 7), Vector2i(3, 7), Vector2i(4, 7), Vector2i(3, 8), Vector2i(3, 9),
			Vector2i(8, 3), Vector2i(7, 4), Vector2i(8, 4), Vector2i(9, 4), Vector2i(8, 5)]
	var furn := {}
	for c: Vector2i in counters:
		furn[at.call(c.x, c.y)] = "f_counter"
	var snap: Snapshot = scene.call(data, tables, {}, furn, [])
	var pos: Array = (data as Dictionary)["submaps"][0]["pos"]
	terrain.set_snapshot(snap)
	cat.set_snapshot(snap)
	var r := PropMesher.new(snap, terrain, cat).build(Vector3i(int(pos[0]), int(pos[1]), int(pos[2])))
	var sides := {"single": [], "end_left": [Vector3.RIGHT], "end_right": [Vector3.LEFT], "middle": [Vector3.RIGHT, Vector3.LEFT],
			"corner": [Vector3.RIGHT, Vector3.BACK], "tee": [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK],
			"cross": [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]}
	var count := {}
	var meets := true
	for n: String in names:
		var xfs: Array = r.models.get(reg.models.get_model("furniture/c_%s.glb" % n), [])
		count[n] = xfs.size()
		for xf: Transform3D in xfs:
			var tile := Vector2i(floori(xf.origin.x), floori(xf.origin.z))
			var around := 0
			for d: Vector2i in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
				around += 1 if counters.has(tile + d) else 0
			meets = meets and around == (sides[n] as Array).size()
			for s: Vector3 in sides[n]:
				var w := (xf.basis * s).normalized()
				meets = meets and counters.has(tile + Vector2i(roundi(w.x), roundi(w.z)))
	_check.call(count["single"] == 1 and count["end_left"] + count["end_right"] == 9 and count["middle"] == 4 and count["corner"] == 1
			and count["tee"] == 1 and count["cross"] == 1,
			"joins: an L, a T and a cross draw their ends, middles, corner, tee and cross; a lone one the plain model " + str(count))
	_check.call(meets, "joins: each piece's joining sides meet its neighbours, and only them")
	var turned := true
	for links: int in range(1, 16):   # shape-local bits -> the sides the piece must join
		var j := PropMesher.join_of(links)
		var b := PropMesher.MODEL_TURN.basis * Basis(Vector3.UP, int(j[1]) * PI / 2.0)
		var got := 0
		for s: Vector3 in sides[j[0]]:
			var w := b * s   # shape-local: front -z (bit 1), +x (2), back +z (4), -x (8)
			got |= 1 if w.z < -0.5 else (2 if w.x > 0.5 else (4 if w.z > 0.5 else 8))
		turned = turned and got == links
	_check.call(turned and PropMesher.join_of(0)[0] == "",
			"joins: every join, one to four sides, gets a piece turned to it; none gets the plain model")


## Terrain models (assets/models/terrain/<id>.glb + a registry entry): they replace the procedural shape,
## turned along wall runs and stair flights (one stairs model per lane, stretched over it); a bad or missing
## model leaves the tile procedural.
func _test_terrain(glb: PackedByteArray, data: Variant, tables: IdTables, scene: Callable, repo: Callable) -> void:
	_write("models/terrain/t_wall.glb", glb)
	_write("models/terrain/t_tree.glb", glb)
	_write("models/terrain/garbage.glb", "not a model".to_utf8_buffer())
	var entries := [
		{"type": "fp3d_model", "id": "t_wall", "kind": "terrain", "mesher": "wall", "model": "terrain/t_wall.glb", "material": "plaster_white"},
		{"type": "fp3d_model", "id": "t_stairs_up", "kind": "terrain", "mesher": "stairs_up", "model": "terrain/t_wall.glb"},
		{"type": "fp3d_model", "id": "t_tree", "kind": "terrain", "model": "terrain/t_tree.glb", "random_yaw": true},
		{"type": "fp3d_model", "id": "t_flat_roof", "kind": "terrain", "mesher": "roof", "model": "terrain/t_tree.glb"},
		{"type": "fp3d_model", "id": "t_brick_wall", "kind": "terrain", "mesher": "wall", "material": "brick", "model": "terrain/garbage.glb"},
		{"type": "fp3d_model", "id": "t_concrete_wall", "kind": "terrain", "model": "terrain/missing.glb"},
	]
	_write("registry_terrain/terrain.json", JSON.stringify(entries).to_utf8_buffer())
	var reg := AssetRegistry.new()
	reg.models.root = _dir.path_join("models")
	reg.load_dir(repo.call("assets/registry"))
	reg.load_dir(_dir.path_join("registry_terrain"))
	var terrain := TerrainCatalog.new()
	terrain.registry = reg
	terrain.set_tables(tables)
	var plain := TerrainCatalog.new()   # the repo registry only: everything procedural
	plain.load_registry_dir(repo.call("assets/registry"))
	plain.set_tables(tables)
	var style := func(id: String) -> TerrainCatalog.Style: return terrain.style_for(tables.index_of("ter", id))
	var wall_m := reg.models.get_tinted("terrain/t_wall.glb", "plaster_white")
	var plain_wall_m := reg.models.get_model("terrain/t_wall.glb")
	var tree_m := reg.models.get_model("terrain/t_tree.glb")
	var wall: TerrainCatalog.Style = style.call("t_wall")
	_check.call(wall.model != null and wall.model == wall_m and wall.kind == TerrainCatalog.Kind.WALL and wall.model.tint == "plaster_white",
			"a terrain id with a model entry gets its model (tinted by its material)")
	var pine: TerrainCatalog.Style = style.call("t_tree_pine")
	_check.call(pine.model == tree_m and pine.random_yaw and pine.kind == TerrainCatalog.Kind.TREE,
			"a tree without an entry takes t_tree's model through looks_like")
	var brick: TerrainCatalog.Style = style.call("t_brick_wall")
	var concrete: TerrainCatalog.Style = style.call("t_concrete_wall")
	_check.call(brick.model == null and brick.kind == TerrainCatalog.Kind.WALL and brick.color == CddaPalette.material("brick")
			and "\n".join(terrain.warnings).contains("garbage.glb"), "a bad terrain model falls back to the entry's mesher, with a warning")
	_check.call(concrete.model == null and concrete.kind == TerrainCatalog.Kind.WALL and "\n".join(terrain.warnings).contains("missing.glb"),
			"a model-only terrain entry whose file is missing: the procedural shape from the flags")

	var at := func(x: int, y: int) -> int: return y * 12 + x
	var ter := {at.call(4, 5): "t_wall", at.call(5, 5): "t_wall", at.call(6, 5): "t_wall",   # east-west run
			at.call(9, 2): "t_wall", at.call(9, 3): "t_wall", at.call(9, 4): "t_wall",        # north-south run
			at.call(2, 8): "t_stairs_up", at.call(3, 8): "t_wall",                            # rises east, to the wall
			at.call(5, 10): "t_stairs_up", at.call(6, 10): "t_stairs_up", at.call(7, 10): "t_stairs_up",   # a 2 x 3 flight
			at.call(5, 11): "t_stairs_up", at.call(6, 11): "t_stairs_up", at.call(7, 11): "t_stairs_up",   # (a wall east)
			at.call(8, 10): "t_wall", at.call(8, 11): "t_wall",
			at.call(8, 9): "t_tree_pine", at.call(10, 7): "t_flat_roof",
			at.call(2, 2): "t_brick_wall", at.call(2, 4): "t_concrete_wall"}
	var snap: Snapshot = scene.call(data, tables, ter, {}, [])
	var sm: Snapshot.Submap = null
	for p: Vector3i in snap.submaps:
		if (snap.submaps[p] as Snapshot.Submap).ter[at.call(5, 5)] == tables.index_of("ter", "t_wall"):
			sm = snap.submaps[p]
	if sm == null:
		_check.call(false, "terrain model scene built")
		return
	terrain.set_snapshot(snap)
	plain.set_snapshot(snap)
	var r := TerrainMesher.new(snap, terrain).build(sm.pos)
	var r0 := TerrainMesher.new(snap, plain).build(sm.pos)
	var walls: Array = r.models.get(wall_m, [])
	var stair_xfs: Array = r.models.get(plain_wall_m, [])
	_check.call(walls.size() == 9 and not stair_xfs.is_empty() and (r.models.get(tree_m, []) as Array).size() == 1
			and r0.models.is_empty(), "terrain models listed: 9 walls, the stairs, the pine (%d, %d)" % [walls.size(), r.models.size()])
	var xf_at := func(xfs: Array, x: int, y: int) -> Variant:
		for xf: Transform3D in xfs:
			if xf.origin.is_equal_approx(Vector3(x + 0.5, xf.origin.y, y + 0.5)):
				return xf
		return null
	var ew: Variant = xf_at.call(walls, 5, 5)
	var ns: Variant = xf_at.call(walls, 9, 3)
	_check.call(ew != null and is_zero_approx((ew as Transform3D).origin.y) and (ew as Transform3D).basis.is_equal_approx(Basis.IDENTITY),
			"a wall model in an east-west run: tile centre on its floor, unturned (x along the run, front south)")
	_check.call(ns != null and ((ns as Transform3D).basis * Vector3.RIGHT).is_equal_approx(Vector3(0, 0, -1))
			and ((ns as Transform3D).basis * Vector3.BACK).is_equal_approx(Vector3.RIGHT),
			"a wall model in a north-south run turns its x along the run (front east)")
	var stairs: Variant = xf_at.call(r.models.get(plain_wall_m, []), 2, 8)
	_check.call(stairs != null and ((stairs as Transform3D).basis * Vector3.BACK).is_equal_approx(Vector3.LEFT),
			"a stairs model: bottom step at the front (west), rising east toward the wall")
	# The 2 x 3 block is one flight (which way it rises depends on the level above): each lane's bottom square
	# draws one model at the lane's middle, its front (model +z) down the flight and stretched over the lane.
	var kind_at := TerrainMesher.kind_lookup(snap, terrain)
	var walk := func(k: int) -> bool: return k in TerrainMesher.WALKABLE
	var corner := CddaCoords.sm_to_ms(sm.pos)
	var lanes := 0
	var longest := 0
	var lanes_ok := true
	for y in [10, 11]:
		for x in [5, 6, 7]:
			var f := TerrainMesher.stair_flight(corner + Vector3i(x, y, 0), kind_at, TerrainCatalog.Kind.STAIRS_UP, walk)
			if f.y > 0:
				continue
			lanes += 1
			longest = maxi(longest, f.z)
			var rise := Vector3(TerrainMesher.DIRS[f.x].x, 0, TerrainMesher.DIRS[f.x].y)
			var mid := Vector3(x + 0.5, 0, y + 0.5) + rise * (f.z - 1) * 0.5
			var found := 0
			for xf: Transform3D in stair_xfs:
				if xf.origin.is_equal_approx(Vector3(mid.x, xf.origin.y, mid.z)):
					found += 1
					lanes_ok = lanes_ok and (xf.basis * Vector3.BACK).is_equal_approx(-rise * f.z) \
							and is_equal_approx((xf.basis * Vector3.RIGHT).length(), 1.0) and (xf.basis * Vector3.UP).is_equal_approx(Vector3.UP)
			lanes_ok = lanes_ok and found == 1
	_check.call(lanes_ok and lanes >= 2 and longest >= 2 and stair_xfs.size() == lanes + 1
			and _solid_in(r, 5, 10) == 0 and _solid_in(r, 6, 11) == 0 and _solid_in(r0, 6, 11) > 0,
			"a 2 x 3 flight: one stairs model per lane, at its middle, stretched over it (%d lanes, %d models)" % [lanes, stair_xfs.size()])
	_check.call(_solid_in(r, 5, 5) == 0 and _solid_in(r0, 5, 5) > 0 and _solid_in(r, 2, 8) == 0 and _solid_in(r0, 2, 8) > 0
			and r.vertices < r0.vertices, "no procedural geometry on model tiles (%d vs %d vertices)" % [r.vertices, r0.vertices])
	_check.call(_solid_in(r, 8, 9) > 0 and _solid_in(r, 8, 9, 0.05) == 0 and _solid_in(r0, 8, 9, 0.05) > 0,
			"a tree model keeps the ground slab under it, without the procedural trunk")
	var roof: Variant = xf_at.call(r.roof_models.get(tree_m, []), 10, 7)
	_check.call(roof != null and is_equal_approx((roof as Transform3D).origin.y, TerrainMesher.ROOF_LIFT) and _tris_in(r.roof, 10, 7) == 0 and _tris_in(r0.roof, 10, 7) > 0,
			"a roof model goes to roof_models, lifted like the roof slab, and replaces the slab")
	_check.call(_solid_in(r, 2, 2) > 0 and _solid_in(r, 2, 4) > 0 and _solid_in(r, 2, 2) == _solid_in(r0, 2, 2),
			"walls with a bad or missing model stay procedural")
	var again := TerrainMesher.new(snap, terrain).build(sm.pos)
	_check.call(again.models.get(tree_m, []) == r.models.get(tree_m, []), "a random-yaw terrain model turns the same every rebuild")

	var world := WorldView.new()
	world.catalog = terrain
	world.props = PropCatalog.new(reg)
	world.set_id_tables(tables)
	world.apply_snapshot(snap)
	var node := world.node_of(sm.pos)
	var holder := node.get_node_or_null("terrain_models") if node else null
	var roof_holder := node.get_node_or_null("terrain_roof_models") if node else null
	_check.call(holder != null and holder.get_child_count() == 3 * wall_m.parts.size() and holder.get_child(0) is MultiMeshInstance3D
			and roof_holder != null, "the world draws terrain models as multimeshes (one per model part)")
	world.set_roofs_visible(false)
	_check.call(roof_holder != null and not (roof_holder as Node3D).visible and (holder as Node3D).visible,
			"terrain roof models hide with the roofs")
	world.free()


## Procedural triangles on tile (x, y): terrain and caps (wall tops under a loaded floor go to caps).
static func _solid_in(r: TerrainMesher.Result, x: int, y: int, min_y := -INF) -> int:
	return _tris_in(r.terrain, x, y, min_y) + _tris_in(r.caps, x, y, min_y)


## Triangles of a mesh whose centre lies on tile (x, y) (submap-local, its edges included: a wall's sides),
## at or above min_y. The test scenes keep these tiles' neighbours free of faces on the shared edges.
static func _tris_in(mesh: ArrayMesh, x: int, y: int, min_y := -INF) -> int:
	if mesh == null:
		return 0
	var n := 0
	for s in mesh.get_surface_count():
		var v: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for i in range(0, v.size() - 2, 3):
			var c := (v[i] + v[i + 1] + v[i + 2]) / 3.0
			if c.x >= x - 0.001 and c.x <= x + 1.001 and c.z >= y - 0.001 and c.z <= y + 1.001 and c.y >= min_y:
				n += 1
	return n


## Monster models (docs/MODELS.md): hit_ regions are hidden and kept by id; the registry's `monster` entries
## by id, then looks_like (the figures: run_figures).
## Every model the game's own registry names (assets/registry): it loads without warnings, keeps to the
## docs/MODELS.md budgets and sits as the docs say.
func _test_repo_models(repo: Callable) -> void:
	var dir: String = repo.call("assets/registry")
	var reg := AssetRegistry.new()
	reg.load_dir(dir)
	var seen := {}
	var bad := PackedStringArray()
	for f: String in DirAccess.get_files_at(dir):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(f))) if f.ends_with(".json") else null
		for d: Variant in (data if data is Array else []):
			if not (d is Dictionary and d.has("model")):
				continue
			var ids: Variant = d.get("id")
			for id: Variant in (ids if ids is Array else [ids]):
				var e := reg.entry(str(id), str(d.get("kind")))   # the entry that won (later files override)
				if e == null or e.model.is_empty() or seen.has(e.model + "|" + e.kind):
					continue
				seen[e.model + "|" + e.kind] = true
				var why := model_fault(reg.models.get_model(e.model), e.kind)
				if not why.is_empty():
					bad.append("%s: %s" % [e.model, why])
				for piece: String in e.joins:
					var p: String = e.joins[piece]
					if not seen.has(p + "|join"):
						seen[p + "|join"] = true
						var pw := piece_fault(reg.models.get_model(p))
						if not pw.is_empty():
							bad.append("%s: %s" % [p, pw])
	_check.call(seen.size() >= 59 and bad.is_empty() and reg.all_warnings().is_empty(),
			"the game's %d models load, keep to the budgets and sit right %s %s" % [seen.size(), bad, reg.all_warnings()])
	var fridge := reg.models.get_model("furniture/f_fridge.glb")
	var cup := reg.models.get_model("furniture/f_cupboard.glb")
	var kinds := func(m: ModelLibrary.Model) -> Array:
		return [] if m == null else m.movers.map(func(v: ModelLibrary.Mover) -> String: return v.kind)
	var outward := func(m: ModelLibrary.Model) -> bool:   # each door's middle swings toward the front (+z)
		return m != null and m.movers.all(func(v: ModelLibrary.Mover) -> bool: return (Basis(v.axis, v.max_amount) * v.size.get_center()).z > v.size.get_center().z + 0.05)
	_check.call(kinds.call(fridge) == ["door", "door"] and fridge.surfaces.size() == 5 and outward.call(fridge)
			and fridge.movers.any(func(v: ModelLibrary.Mover) -> bool: return v.surfaces.size() == 3)
			and kinds.call(cup) == ["door"] and cup.surfaces.size() == 2 and outward.call(cup)
			and kinds.call(reg.models.get_model("furniture/f_counter.glb")) == []
			and reg.models.get_model("furniture/f_bookcase.glb").surfaces.size() == 4,
			"the fridge's and the cupboard's doors open outward, the fridge's bins ride its door, shelves are surfaces; the counter's door stays shut")
	var lifts := func(m: ModelLibrary.Model) -> bool:   # one lid, its middle rising as it opens
		return m != null and kinds.call(m) == ["lid"] and m.movers.all(func(v: ModelLibrary.Mover) -> bool: return (Basis(v.axis, v.max_amount) * v.size.get_center()).y > v.size.get_center().y + 0.05)
	var bin := reg.models.get_model("furniture/f_trashcan.glb")
	var chest := reg.models.get_model("furniture/f_chest.glb")
	_check.call(lifts.call(bin) and bin.surfaces.size() == 1 and lifts.call(chest) and chest.surfaces.size() == 1
			and reg.models.get_model("furniture/f_workbench.glb").surfaces.size() == 1
			and reg.models.get_model("furniture/f_crate_o.glb").surfaces.size() == 1,
			"the bin's and the chest's lids lift; the bin, chest, workbench and open crate have a surface")
	var dresser := reg.models.get_model("furniture/f_dresser.glb")
	var sealed := reg.models.get_model("furniture/f_crate_c.glb")
	_check.call(kinds.call(dresser) == ["drawer", "drawer"]
			and dresser.movers.all(func(v: ModelLibrary.Mover) -> bool: return v.axis.is_equal_approx(Vector3.BACK) and v.surfaces.size() == 1)
			and sealed != null and kinds.call(sealed) == [] and sealed.surfaces.is_empty(),
			"the dresser's two drawers slide to the front, an item surface in each; the sealed crate has no parts")
	var corner := reg.models.get_model("furniture/f_counter_corner.glb")
	var cb := corner.aabb if corner != null else AABB()
	_check.call(reg.entry("f_counter", "furniture").joins.get("corner") == "furniture/f_counter_corner.glb" and corner != null
			and cb.position.is_equal_approx(Vector3(-0.45, 0.0, -0.45)) and cb.end.x > 0.49 and cb.end.z > 0.49 and corner.surfaces.size() == 1,
			"the counter's corner piece: flush with the counters' backs on its left and back, out to the tile's edges where the runs go on %s" % cb)


## Why a model breaks docs/MODELS.md ("" when it doesn't): triangle and texture budgets by kind, the bottom
## centre at the origin, items of a real size, furniture inside its 1 m tile and one storey.
## A join piece (registry `joins`): the furniture budgets, standing on the floor inside its tile; unlike a
## lone model it needn't be centred (a corner reaches the tile's edges only where its runs go on).
static func piece_fault(m: ModelLibrary.Model) -> String:
	if m == null:
		return "doesn't load"
	var box := m.aabb
	if m.triangles > 15000 or m.image_bytes > 2048 * 2048 * 4:
		return "over budget (%d triangles, %d bytes of texture)" % [m.triangles, m.image_bytes]
	if absf(box.position.y) > 0.01 or box.position.x < -0.5 or box.position.z < -0.5 or box.end.x > 0.5 or box.end.z > 0.5 or box.size.y > 3.0:
		return "not on the floor inside its tile %s" % box
	return ""


static func model_fault(m: ModelLibrary.Model, kind: String) -> String:
	if m == null:
		return "doesn't load"
	var box := m.aabb
	var item := kind == "item"
	if m.triangles > (5000 if item else 15000):
		return "%d triangles" % m.triangles
	if m.image_bytes > (1024 * 1024 if item else 2048 * 2048) * 4:
		return "%d bytes of texture" % m.image_bytes
	if absf(box.position.y) > 0.01 or absf(box.get_center().x) > 0.01 or absf(box.get_center().z) > 0.01:
		return "not standing on its bottom centre %s" % box
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	if item and (longest < 0.01 or longest > 2.0):
		return "%.2f m long" % longest
	if not item and (box.size.x > 1.0 or box.size.z > 1.0 or box.size.y > 3.0):
		return "doesn't fit its tile %s" % box.size
	return ""


func _test_creature_model() -> void:
	var reg := _monster_registry()
	var lib := _lib()
	var m := lib.get_model("monsters/ghoul.glb")
	if m == null:
		_check.call(false, "creature model: loads " + str(lib.warnings))
		return
	var ids := []
	for h: Array in m.hits:
		ids.append(h[0])
	ids.sort()
	_check.call(m.parts.size() == 2 and ids == ["", "arm_l", "head", "leg", "leg", "tail"] and not m.has_marker("hit_head")
			and is_equal_approx(m.aabb.end.y, 1.7), "creature model: body and head drawn; the hit_ regions hidden, kept by id "
			+ "(pieces share one; a bad name has none) %s" % [ids])
	var H := ModelLibrary
	_check.call(H.hit_id("hit_leg_2") == "leg" and H.hit_id("hit_arm_l") == "arm_l" and H.hit_id("hit_leg_0") == "leg_0"
			and H.hit_id("hit_") == "" and H.hit_id("hit_Head") == "" and H.hit_id("hit_" + "a".repeat(40)) == ""
			and H.hit_id("head") == "" and H.hit_id("hit_eye_99") == "eye" and H.hit_id("hit_eye_100") == "eye_100",
			"creature model: a region's id drops its piece number; only short lower-case ids")
	var ghoul := _mon("mon_ghoul", "", "human", {"head": true, "leg": true})
	var look := CreatureView.model_for(reg, ghoul)
	var like := CreatureView.model_for(reg, _mon("mon_ghoul_fast", "mon_ghoul", "human", {}))
	var fell := CreatureView.model_for(reg, _mon("mon_bad", "mon_plain", "dog", {}))
	_check.call(look.size() == 2 and (look[0] as ModelLibrary.Model).path == "monsters/ghoul.glb" and like.size() == 2
			and like[0] == look[0] and fell.size() == 2 and (fell[0] as ModelLibrary.Model).path == "monsters/plain.glb"
			and CreatureView.model_for(reg, _mon("mon_zed", "", "", {})).is_empty() and CreatureView.model_for(reg, null).is_empty()
			and CreatureView.model_for(null, ghoul).is_empty(), "creature model: a monster's own registry entry, else its "
			+ "looks_like's; a model that doesn't load is passed over; none: the placeholder " + str(reg.all_warnings().slice(0, 2)))


## The monster test models and a registry of them (in the test folder): mon_ghoul (with hit regions), mon_plain
## (none, scale 2), mon_bad (not a model), mon_huge (scale 100).
func _monster_registry() -> AssetRegistry:
	DirAccess.make_dir_recursive_absolute(_dir.path_join("models/monsters"))
	DirAccess.make_dir_recursive_absolute(_dir.path_join("registry_monster"))
	_write("models/monsters/ghoul.glb", ghoul_glb())
	_write("models/monsters/plain.glb", ghoul_glb(false))
	_write("models/monsters/bad.glb", "not a model".to_utf8_buffer())
	var entries := [
		{"type": "fp3d_model", "kind": "monster", "id": "mon_ghoul", "model": "monsters/ghoul.glb"},
		{"type": "fp3d_model", "kind": "monster", "id": "mon_plain", "model": "monsters/plain.glb", "scale": 2.0},
		{"type": "fp3d_model", "kind": "monster", "id": "mon_bad", "model": "monsters/bad.glb"},
		{"type": "fp3d_model", "kind": "monster", "id": "mon_huge", "model": "monsters/plain.glb", "scale": 100.0},
	]
	_write("registry_monster/monsters.json", JSON.stringify(entries).to_utf8_buffer())
	var reg := AssetRegistry.new()
	reg.load_dir(_dir.path_join("registry_monster"))
	return reg


## Figures drawn as monster models (run from run_tests.gd once the root is in the tree: rays need global
## transforms): the model instead of the shapes, its hit regions as hit zones (weak points, body parts on a
## human body, the rest the body), else the hidden shapes; how it moves; the scale bounded; corpses.
func run_figures(root: Node, check: Callable) -> void:
	_check = check
	_dir = TestDir.global("model_test")
	_remove(_dir)
	var reg := _monster_registry()
	var ghoul := _mon("mon_ghoul", "", "human", {"head": true, "leg": true})
	var fig := CreatureView._figure(Snapshot.Creature.MONSTER, ghoul, "k", CreatureView.model_for(reg, ghoul))
	root.add_child(fig)
	fig.global_position = Vector3(100, 0, 100)
	var model_node := fig.get_node_or_null("body/model") as Node3D
	var hidden := model_node != null
	var drawn := 0
	if model_node != null:
		for c in fig.get_node("body").get_children():
			if c != model_node and (c as Node3D).visible:
				hidden = false
		for c in model_node.get_children():
			drawn += int((c as Node3D).visible)
	var zones := {}
	for z: Array in fig.hit_zones():
		zones[z[1]] = int(zones.get(z[1], 0)) + 1
		drawn += 100 * int((z[0] as Node3D).visible)
	_check.call(hidden and drawn == 2 and zones.size() == 4 and zones.get("head") == 1 and zones.get("leg") == 2
			and zones.get("arm_l") == 1 and zones.get("torso") == 2 and is_equal_approx(fig.top, 1.7)
			and model_node.transform.basis.z.z < -0.99, "creature model: drawn instead of the shapes (hidden), facing -Z, as tall "
			+ "as the model; hit zones its hidden regions: weak points, body parts on a human body, the rest the body %s" % [zones])
	var head := String(BulletPhysics._hit_figure(Vector3(100, 1.55, 90), Vector3(0, 0, 20), {7: fig}, 0).get("zone", ""))
	var leg := String(BulletPhysics._hit_figure(Vector3(100.12, 0.3, 90), Vector3(0, 0, 20), {7: fig}, 0).get("zone", ""))
	_check.call(head == "head" and leg == "leg", "creature model: a shot at the head hits its head region, one low its leg (%s, %s)" % [head, leg])
	fig.attack(Vector3(100, 0, 90))
	for i in 4:   # animate() takes at most 0.1 s a step
		fig.animate(CreatureFigure.ATTACK_S / 8.0)
	var lunged := model_node.position.z < -0.1
	for i in 10:
		fig.animate(0.05)
	fig.hurt()
	var mesh0 := model_node.get_child(0) as MeshInstance3D
	var flinch := mesh0.material_overlay == CreatureFigure._hurt_material()
	for i in 10:
		fig.animate(0.05)
	var calm := mesh0.material_overlay == null and model_node.transform.is_equal_approx(fig._model_base)
	fig.die()
	_check.call(lunged and flinch and calm and fig.hit_zones().is_empty(), "creature model: lunges, flinches red and settles; no hit "
			+ "zones while it dies")
	root.remove_child(fig)
	fig.free()
	var plain := CreatureView._figure(Snapshot.Creature.MONSTER, _mon("mon_plain", "", "human", {"head": true}), "k",
			CreatureView.model_for(reg, _mon("mon_plain", "", "", {})))
	var huge := CreatureView._figure(Snapshot.Creature.MONSTER, _mon("mon_huge", "", "", {}), "k",
			CreatureView.model_for(reg, _mon("mon_huge", "", "", {})))
	root.add_child(plain)
	root.add_child(huge)
	var shape_zones := {}
	for z: Array in plain.hit_zones():
		shape_zones[z[1]] = true
	_check.call(is_equal_approx(plain.top, 3.4) and shape_zones.has("head") and shape_zones.has("torso")
			and huge.top <= ModelLibrary.MAX_MODEL_SIZE + 0.01 and huge.top > 15.0, "creature model: the entry's scale; without "
			+ "regions the hidden shapes are the zones %s; at most %d m a side (%.1f)" % [shape_zones.keys(), ModelLibrary.MAX_MODEL_SIZE, huge.top])
	plain.lie_dead()
	var dark := (plain.get_node("body/model").get_child(0) as MeshInstance3D).material_overlay == CreatureFigure._dead_material()
	plain.show_corpse_state(Snapshot.CORPSE_SKINNED)
	var raw := (plain.get_node("body/model").get_child(0) as MeshInstance3D).material_overlay == CreatureFigure._raw_material()
	_check.call(dark and raw, "creature model: a corpse's model lies darker; skinned it is raw")
	root.remove_child(plain)
	root.remove_child(huge)
	plain.free()
	huge.free()
	_remove(_dir)

static func _mon(id: String, looks_like: String, bodytype: String, weak: Dictionary) -> IdTables.Def:
	var d := IdTables.Def.new()
	d.id = id
	d.looks_like = looks_like
	d.bodytype = bodytype
	d.size = 3
	d.weakpoints = weak
	return d


func _write(rel: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(_dir.path_join(rel), FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


## Deletes the test folder (only under the run's model_test).
func _remove(dir: String) -> void:
	if not dir.begins_with(TestDir.global("model_test")):
		return
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		da.remove(f)
	for sub in da.get_directories():
		if da.is_link(dir.path_join(sub)):
			DirAccess.remove_absolute(dir.path_join(sub))   # the link only, not what it points at
		else:
			_remove(dir.path_join(sub))
	DirAccess.remove_absolute(dir)


## A library whose loads make an empty model after a short wait (no file, nothing for the renderer), for checks of
## the cache from several threads.
class SlowLoads extends ModelLibrary:
	func _load(rel: String) -> ModelLibrary.Model:
		OS.delay_usec(2000)
		var m := ModelLibrary.Model.new()
		m.path = rel
		return m
