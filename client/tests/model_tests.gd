extends RefCounted
## Model loading (ModelLibrary, docs/MODELS.md): a tiny .glb built here with GLTFDocument, its markers,
## the caps, hostile files and paths, the strict glTF checks (one small file per rule), the cache, links,
## registry fallbacks, model props and item piles on model surfaces.
## Run from run_tests.gd; files go to user://model_test_<process id> and are removed afterwards.

var _check: Callable
var _dir := ""


func run(check: Callable, data: Variant, tables: IdTables, scene: Callable, repo: Callable) -> void:
	print("models (.glb)")
	_check = check
	# one folder per process: test runs of other checkouts share user://
	_dir = ProjectSettings.globalize_path("user://model_test_%d" % OS.get_process_id())
	_remove(_dir)
	DirAccess.make_dir_recursive_absolute(_dir.path_join("models/furniture"))
	DirAccess.make_dir_recursive_absolute(_dir.path_join("registry"))
	var glb := cupboard_glb()
	_write("models/furniture/cupboard.glb", glb)
	_test_markers()
	_test_colliders()
	_test_caps(glb)
	_test_hostile(glb)
	_test_strict()
	_test_index_max()
	_test_cache(glb)
	_test_links(glb)
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


## One small .glb per rule of the strict checks; the one-triangle model itself loads.
func _test_strict() -> void:
	_write("models/furniture/tri.glb", tri_glb())
	var lib := _lib()
	_check.call(lib.get_model("furniture/tri.glb") != null, "the one-triangle model loads " + str(lib.warnings))
	_write("models/furniture/tri.glb", tri_glb({"extensionsUsed": ["KHR_materials_unlit"], "materials": [{"extensions": {"KHR_materials_unlit": {}}}],
			"meshes/0/primitives/0/material": 0, "nodes/0/extras": {"extensions": {"anything": 1}}}))
	lib = _lib()
	_check.call(lib.get_model("furniture/tri.glb") != null, "known extensions and extras still load " + str(lib.warnings))
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
	lib = _lib()
	var got: Array = [null]
	var task := WorkerThreadPool.add_task(func() -> void: got[0] = lib.get_model("furniture/cupboard.glb"))
	var here := lib.get_model("furniture/cupboard.glb")
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
		if da.is_link(dir.path_join(sub)):
			DirAccess.remove_absolute(dir.path_join(sub))   # the link only, not what it points at
		else:
			_remove(dir.path_join(sub))
	DirAccess.remove_absolute(dir)
