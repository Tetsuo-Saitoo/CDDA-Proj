extends RefCounted
## Model loading (ModelLibrary, docs/MODELS.md): a tiny .glb built here with GLTFDocument, its markers,
## the caps, hostile files and paths, registry fallbacks, model props and item piles on model surfaces.
## Run from run_tests.gd; files go to user://model_test and are removed afterwards.

var _check: Callable
var _dir := ""


func run(check: Callable, data: Variant, tables: IdTables, scene: Callable, repo: Callable) -> void:
	print("models (.glb)")
	_check = check
	_dir = ProjectSettings.globalize_path("user://model_test")
	_remove(_dir)
	DirAccess.make_dir_recursive_absolute(_dir.path_join("models/furniture"))
	DirAccess.make_dir_recursive_absolute(_dir.path_join("models/terrain"))
	DirAccess.make_dir_recursive_absolute(_dir.path_join("registry"))
	DirAccess.make_dir_recursive_absolute(_dir.path_join("registry_terrain"))
	var glb := cupboard_glb()
	_write("models/furniture/cupboard.glb", glb)
	_test_markers()
	_test_tint()
	_test_caps(glb)
	_test_hostile(glb)
	_test_props(data, tables, scene, repo)
	_test_terrain(glb, data, tables, scene, repo)
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


## Terrain models (assets/models/terrain/<id>.glb + a registry entry): they replace the procedural shape,
## turned along wall runs and stair flights; a bad or missing model leaves the tile procedural.
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
	_check.call(walls.size() == 7 and (r.models.get(plain_wall_m, []) as Array).size() == 1 and (r.models.get(tree_m, []) as Array).size() == 1
			and r0.models.is_empty(), "terrain models listed: 7 walls, the stairs, the pine (%d, %d)" % [walls.size(), r.models.size()])
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


func _write(rel: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(_dir.path_join(rel), FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


## Deletes the test folder (only under user://model_test).
func _remove(dir: String) -> void:
	if not dir.begins_with(ProjectSettings.globalize_path("user://model_test")):
		return
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		da.remove(f)
	for sub in da.get_directories():
		_remove(dir.path_join(sub))
	DirAccess.remove_absolute(dir)
