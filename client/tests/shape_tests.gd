extends RefCounted
## Block H1, registry entries: every placeholder the registry names is a shape PropShapes builds, and every
## shape builds something that stands on its tile. Run by run_tests.gd.

var _check: Callable


func run(check: Callable, repo: Callable) -> void:
	_check = check
	print("placeholder shapes (H1)")
	_test_registry(repo)
	_test_shapes()


func _test_registry(repo: Callable) -> void:
	var dir: String = repo.call("assets/registry")
	var bad := PackedStringArray()
	var count := 0
	for name in DirAccess.get_files_at(dir):
		if not name.ends_with(".json"):
			continue
		var list: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(name)))
		if not list is Array:
			bad.append(name)
			continue
		for e: Variant in list:
			if e is Dictionary and e.has("placeholder"):
				count += 1
				if not PropShapes.has_shape(str(e["placeholder"])):
					bad.append("%s: %s" % [name, e["placeholder"]])
	_check.call(count > 100 and bad.is_empty(), "shapes: the registry's %d placeholders are all shapes %s" % [count, bad])


## Each shape, alone and with every neighbour joined: some faces, nothing below the floor, nothing past the
## tile's edge but the few that reach over it (street lights, clotheslines, signs, dishes ...; items are drawn
## scaled to their size), not taller than a utility pole.
func _test_shapes() -> void:
	var tall := ["street_light", "pole", "clothesline", "antenna", "sign", "dish", "bulletin", "dumpster", "item_long",
			"item_corpse", "panel_wall", "cable"]
	var bad := PackedStringArray()
	for shape: String in PropShapes.NAMES:
		for links: int in [0, 15]:
			var solid := TerrainMesher.Buf.new()
			var b := PropShapes.Builder.new(solid, TerrainMesher.Buf.new())
			var rng := RandomNumberGenerator.new()
			rng.seed = 7
			PropShapes.build(shape, b, Color(0.5, 0.5, 0.5), Color(0.6, 0.2, 0.2), Color(0.2, 0.5, 0.2), links, 1.0, rng)
			if solid.verts.is_empty() and not shape.begins_with("item_") and shape != "trap_plate":
				bad.append("%s/%d: nothing" % [shape, links])
				continue
			for v in solid.verts:
				var edge := maxf(absf(v.x), absf(v.z))
				if v.y < -0.001 or v.y > 8.0 or (edge > 0.5 + 0.001 and shape not in tall and not shape.begins_with("item_")):
					bad.append("%s/%d: %s" % [shape, links, v])
					break
	_check.call(bad.is_empty(), "shapes: each builds on its tile %s" % bad)
	var count := func(shape: String, links: int) -> int:
		var solid := TerrainMesher.Buf.new()
		PropShapes.build(shape, PropShapes.Builder.new(solid, TerrainMesher.Buf.new()), Color.GRAY, Color.RED,
				Color.GREEN, links, 1.0, RandomNumberGenerator.new())
		return solid.verts.size()
	_check.call(count.call("cable", 1 | 4) < count.call("cable", 15) and count.call("cable", 0) > 0,
			"shapes: a cable runs toward its joined neighbours")
