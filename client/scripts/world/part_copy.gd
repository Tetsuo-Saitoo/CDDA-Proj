class_name PartCopy
extends RefCounted
## C6 vehicle work (lead-vr's hands, install mode): one vehicle part drawn on its own, apart from its vehicle's mesh.
## It is the copy a hand carries (VehicleView.part_copy; the original is hidden meanwhile: hide_part) and the ghost of
## a part about to be installed on a square (highlight_square with a vpart). Drawn as VehicleView draws it: its kind's
## shapes (VehicleView.shapes) in its colour, or a plain box at its spot (PartSpot.spot_of) for a part not drawn as a
## shape (an alternator, a battery, a seatbelt). Visual only: CDDA never puts a part in a hand.

const K := VehicleView.Kind
const Look := VehicleView.Look


## A part of type `def` with hp_frac `hp` (0..255) and state `state` on square `m` of a vehicle with cells `cells`
## (PartSpot.cells_of; {} for none): its pieces as VehicleView.place gives them ({Look: [[Transform3D, Color], ...]}),
## in the mount grid. A wheel stands out on the body's side, as VehicleView draws it.
static func boxes(def: IdTables.Def, hp: int, state: int, cells: Dictionary, m: Vector2i) -> Dictionary:
	var kind := VehicleView.kind_of(def, state)
	var at := Vector3(m.x, 0.0, m.y)
	if kind == K.WHEEL:
		at.z += PartSpot.wheel_side(cells, m) * VehicleView.WHEEL_OUT
	var by_look := {}
	if not VehicleView.shapes(kind).is_empty():
		VehicleView.place(by_look, kind, VehicleView.color_of(kind, def, hp, state), at, Basis(),
				(state & Snapshot.VPART_BROKEN) != 0)
		return by_look
	var box: AABB = PartSpot.spot_of(def)[0]
	var col := CddaPalette.fg(def.color, VehicleView.DEFAULT_COLOR) if def != null else VehicleView.DEFAULT_COLOR
	by_look[Look.SOLID] = [[Transform3D(Basis.from_scale(box.size), at + box.get_center()), VehicleView.damaged(col, hp, state)]]
	return by_look


## The box around `by_look`'s pieces (each a unit box or cylinder, scaled and placed); AABB() for none.
static func bounds(by_look: Dictionary) -> AABB:
	var out := AABB()
	var first := true
	for look: int in by_look:
		for e: Array in by_look[look]:
			var b: AABB = (e[0] as Transform3D) * AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
			out = b if first else out.merge(b)
			first = false
	return out


## `by_look` as a mesh, moved by `offset`: the solid pieces and wheels on one surface, glass on another; all in
## `material` when one is given (a tint), else as VehicleView draws them.
static func mesh_of(by_look: Dictionary, offset: Vector3, material: Material = null) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for surf: Array in [[Look.SOLID, [Look.SOLID, Look.WHEEL]], [Look.GLASS, [Look.GLASS]]]:
		var tris := []   # [a, b, c, normal, colour]
		for look: int in surf[1]:
			for e: Array in by_look.get(look, []):
				var xf := Transform3D((e[0] as Transform3D).basis, (e[0] as Transform3D).origin + offset)
				if look == Look.WHEEL:
					VehicleView._cylinder(tris, xf, e[1])
				else:
					VehicleView._box(tris, xf, e[1])
		if tris.is_empty():
			continue
		var v := PackedVector3Array()
		var nr := PackedVector3Array()
		var cl := PackedColorArray()
		for t: Array in tris:
			v.append_array(PackedVector3Array([t[0], t[1], t[2]]))
			nr.append_array(PackedVector3Array([t[3], t[3], t[3]]))
			cl.append_array(PackedColorArray([t[4], t[4], t[4]]))
		var data := []
		data.resize(Mesh.ARRAY_MAX)
		data[Mesh.ARRAY_VERTEX] = v
		data[Mesh.ARRAY_NORMAL] = nr
		data[Mesh.ARRAY_COLOR] = cl
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data)
		mesh.surface_set_material(mesh.get_surface_count() - 1,
				material if material != null else VehicleView._material(surf[0]))
	return mesh


## A node "PartCopy" drawing `by_look` with its origin at `mid` (mount grid): a hand holds it there.
static func node_of(by_look: Dictionary, mid: Vector3) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.name = "PartCopy"
	n.mesh = mesh_of(by_look, -mid)
	return n


## The row of `veh` holding the part `which` ([mount: Vector2i, vpart index]; not a gap filler), -1 for none.
static func row_of(veh: Snapshot.Vehicle, which: Array) -> int:
	if veh == null or which.size() != 2 or not which[0] is Vector2i:
		return -1
	var m: Vector2i = which[0]
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		if veh.parts[j] == m.x and veh.parts[j + 1] == m.y and veh.parts[j + 2] == which[1] \
				and veh.parts[j + 4] & Snapshot.VPART_FILLER == 0:
			return i
	return -1
