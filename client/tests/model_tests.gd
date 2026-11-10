extends RefCounted
## Model loading (ModelLibrary, docs/MODELS.md): a tiny .glb built here with GLTFDocument, its markers,
## the caps, hostile files and paths, registry fallbacks, model props and item piles on model surfaces.
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
	DirAccess.make_dir_recursive_absolute(_dir.path_join("registry"))
	var glb := cupboard_glb()
	_write("models/furniture/cupboard.glb", glb)
	_test_markers()
	_test_caps(glb)
	_test_hostile(glb)
	_test_props(data, tables, scene, repo)
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
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(root, state)
	var out := doc.generate_buffer(state)
	root.free()
	return out


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


## A .glb from a glTF JSON and a binary chunk (for hostile files).
static func glb_of(json: Dictionary, bin := PackedByteArray()) -> PackedByteArray:
	var j := JSON.stringify(json).to_utf8_buffer()
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
	_check.call(not m.fill.is_empty() and m.colliders.size() == 1 and m.colliders[0][0] is ConvexPolygonShape3D,
			"fill volume kept hidden, -convcolonly becomes a convex collider")
	_check.call(m.triangles == 76 and is_equal_approx(m.aabb.size.y, 1.2), "triangles %d, bounds %s" % [m.triangles, m.aabb])
	_check.call(lib.get_model("furniture/cupboard.glb") == m, "cached per path")
	_check.call(ModelLibrary.marker_kind("door_12") == ModelLibrary.Marker.PART and ModelLibrary.marker_kind("door_0") == ModelLibrary.Marker.NONE
			and ModelLibrary.marker_kind("surface_+1") == ModelLibrary.Marker.NONE and ModelLibrary.marker_kind("burner_2") == ModelLibrary.Marker.POINT
			and ModelLibrary.marker_kind("grip_2") == ModelLibrary.Marker.POINT and ModelLibrary.marker_kind("door_100") == ModelLibrary.Marker.NONE,
			"marker names: numbered 1-99 only")


func _test_caps(glb: PackedByteArray) -> void:
	for c: Array in [["max_triangles", 50, "triangles"], ["max_markers", 4, "markers"], ["max_nodes", 5, "nodes"],
			["max_file_bytes", 100, "larger than"]]:
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
			0xFF, 0xC0, 0, 17, 8, 0x13, 0x88, 0, 16, 3, 0, 0, 0, 0, 0, 0])   # 5000 high
	var img := func(bytes: PackedByteArray, mime: String) -> PackedByteArray:
		return glb_of({"asset": asset, "buffers": [{"byteLength": bytes.size()}],
				"bufferViews": [{"buffer": 0, "byteLength": bytes.size()}],
				"images": [{"bufferView": 0, "mimeType": mime}]}, bytes)
	var garbage := PackedByteArray()
	for i in 200:
		garbage.append((i * 37 + 11) % 256)
	var cases := [
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


func _test_props(data: Variant, tables: IdTables, scene: Callable, repo: Callable) -> void:
	_write("models/furniture/garbage.glb", "not a model".to_utf8_buffer())
	var entries := [
		{"type": "fp3d_model", "id": "f_cupboard", "kind": "furniture", "model": "furniture/cupboard.glb", "placeholder": "counter"},
		{"type": "fp3d_model", "id": "f_dresser", "kind": "furniture", "model": "furniture/garbage.glb", "placeholder": "dresser"},
		{"type": "fp3d_model", "id": "f_chair", "kind": "furniture", "model": "furniture/missing.glb"},
		{"type": "fp3d_model", "id": "101_carpentry", "kind": "item", "model": "furniture/cupboard.glb", "scale": 0.25},
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
	var xfs: Array = r.models.get(cupboard.model, [])
	_check.call(r.model_props == 3 and xfs.size() == 3, "model props listed: the cupboard and two books (%d)" % r.model_props)
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
	_check.call((pm.pile_transforms(sm, base, sm.items.slice(Snapshot.PILE_STRIDE, 2 * Snapshot.PILE_STRIDE), {}) as Array).is_empty(),
			"items in the dresser (placeholder, closed) stay hidden")

	var world := WorldView.new()
	world.catalog = terrain
	world.props = cat
	world.set_id_tables(tables)
	world.apply_snapshot(snap)
	var holder := world.node_of(sm.pos).get_node_or_null("models")
	var mms := holder.get_children() if holder else []
	_check.call(mms.size() == 3 and (mms[0] as MultiMeshInstance3D).multimesh.instance_count == 3 and world.prop_counts["models"] >= 3,
			"the world draws one multimesh per model part, an instance per prop")
	world.free()


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
		_remove(dir.path_join(sub))
	DirAccess.remove_absolute(dir)
