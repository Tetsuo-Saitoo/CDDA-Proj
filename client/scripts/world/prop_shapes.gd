class_name PropShapes
extends RefCounted
## Procedural placeholder art for props (registry field `placeholder`, contracts/assets.md): low-poly
## furniture, traps and items built from boxes and 8-sided prisms, with enough trim (handles, seams,
## shelves, cushions) that a room reads well until block H brings models.
##
## Shapes are built in tile-local metres: the tile centre on the floor is the origin, x and z run
## -0.5..0.5, y up, and the front faces -z (north); the caller turns the builder to face another way.
## Item shapes are built at unit size and scaled by the item's size.
##
## Joined tiles (`links`, from PropMesher) draw as one piece: beds, tables, benches, counters, sofas,
## shelves and bathtubs reach the tile edge on linked sides without seams there, with legs only at the
## piece's outer corners; a bed's headboard and pillow go on its head row, the blanket's fold over the
## foot on its foot row (a 2 x 2 block is one double bed with two pillows).

const ALL := TerrainMesher.ALL
const NY := TerrainMesher.NY
const SIDES := ALL & ~NY   # props stand on something: no bottom faces
const X_LINKS := 2 | 8     # shape-local link bits of the +x and -x sides
const Z_LINKS := 1 | 4     # front (-z) and back (+z)

const DARK := Color(0.12, 0.12, 0.13)
const METAL := Color(0.6, 0.62, 0.64)
const METAL_DARK := Color(0.3, 0.31, 0.33)
const WOOD := Color(0.56, 0.4, 0.25)
const WOOD_DARK := Color(0.36, 0.25, 0.16)
const STONE_TOP := Color(0.78, 0.76, 0.72)
const CERAMIC := Color(0.92, 0.92, 0.9)
const LINEN := Color(0.9, 0.88, 0.84)
const TERRACOTTA := Color(0.62, 0.35, 0.22)
const LEAF := Color(0.24, 0.43, 0.19)
const LAMP := Color(0.98, 0.94, 0.78)
const PILLOW := Color(0.94, 0.94, 0.94)
const BATH_WATER := Color(0.55, 0.68, 0.78)

## Where items rest on a shape: `surfaces` heights (items spread over them, largest first, lowest
## first), `rect` the area in shape-local x0, z0, x1, z1, `hide` true when items are inside (closed
## containers). Shapes not listed put items on the floor around them.
const INFO := {
	"chair": {"surfaces": [0.48], "rect": [-0.17, -0.17, 0.17, 0.14]},
	"stool": {"surfaces": [0.65], "rect": [-0.1, -0.1, 0.1, 0.1]},
	"armchair": {"surfaces": [0.52], "rect": [-0.22, -0.28, 0.22, 0.15]},
	"sofa": {"surfaces": [0.52], "rect": [-0.42, -0.33, 0.42, 0.15]},
	"bench": {"surfaces": [0.46], "rect": [-0.42, -0.14, 0.42, 0.14]},
	"park_bench": {"surfaces": [0.46], "rect": [-0.42, -0.16, 0.42, 0.08]},
	"table": {"surfaces": [0.77], "rect": [-0.38, -0.38, 0.38, 0.38]},
	"coffee_table": {"surfaces": [0.41], "rect": [-0.36, -0.24, 0.36, 0.24]},
	"desk": {"surfaces": [0.77], "rect": [-0.42, -0.32, 0.42, 0.32]},
	"workbench": {"surfaces": [0.93], "rect": [-0.42, -0.34, 0.42, 0.34]},
	"counter": {"surfaces": [0.93], "rect": [-0.42, -0.36, 0.42, 0.42]},
	"sink": {"surfaces": [0.88], "rect": [-0.18, -0.24, 0.18, 0.08]},
	"shelf": {"surfaces": [0.13, 0.58, 1.03, 1.48], "rect": [-0.42, -0.06, 0.42, 0.4]},
	"bookcase": {"surfaces": [0.08, 0.53, 0.98, 1.43], "rect": [-0.38, -0.08, 0.38, 0.38]},
	"glass_fridge": {"surfaces": [0.1, 0.6, 1.1], "rect": [-0.32, -0.18, 0.32, 0.36]},
	"display_case": {"surfaces": [0.87], "rect": [-0.38, -0.32, 0.38, 0.38]},
	"glass_cabinet": {"surfaces": [0.32, 0.8, 1.3], "rect": [-0.38, -0.08, 0.38, 0.38]},
	"bed": {"surfaces": [0.58], "rect": [-0.38, -0.4, 0.38, 0.15]},
	"crate_open": {"surfaces": [0.1], "rect": [-0.3, -0.3, 0.3, 0.3]},
	"bathtub": {"surfaces": [0.12], "rect": [-0.38, -0.28, 0.38, 0.28]},
	"shower": {"surfaces": [0.08], "rect": [-0.38, -0.38, 0.38, 0.3]},
	"groundsheet": {"surfaces": [0.02], "rect": [-0.42, -0.42, 0.42, 0.42]},
	"cabinet_tall": {"hide": true}, "dresser": {"hide": true}, "locker": {"hide": true},
	"filing_cabinet": {"hide": true}, "fridge": {"hide": true}, "chest_freezer": {"hide": true},
	"appliance": {"hide": true}, "oven": {"hide": true}, "stove": {"hide": true}, "crate": {"hide": true},
	"cardboard_box": {"hide": true}, "trash_can": {"hide": true}, "recycle_bin": {"hide": true},
	"dumpster": {"hide": true}, "vending": {"hide": true}, "tank": {"hide": true},
}
const FLOOR_INFO := {"surfaces": [0.0], "rect": [-0.42, -0.42, 0.42, 0.42]}


## Builds into vertex-coloured buffers through a transform (tile position, facing, size).
class Builder:
	var solid: TerrainMesher.Buf
	var glass: TerrainMesher.Buf
	var xf := Transform3D.IDENTITY

	func _init(solid_buf: TerrainMesher.Buf, glass_buf: TerrainMesher.Buf) -> void:
		solid = solid_buf
		glass = glass_buf

	func box(lo: Vector3, hi: Vector3, col: Color, faces := SIDES) -> void:
		_box(solid, lo, hi, col, faces)

	func pane(lo: Vector3, hi: Vector3) -> void:
		_box(glass, lo, hi, CddaPalette.GLASS, ALL)

	## Upright prism with `sides` (even) faces on a circle of radius r, standing on c.
	func cyl(c: Vector3, r: float, h: float, col: Color, sides := 8, top := true) -> void:
		var lo: Array[Vector3] = []
		var hi: Array[Vector3] = []
		for i in sides:
			var a := TAU * i / sides
			var v := c + Vector3(cos(a) * r, 0, sin(a) * r)
			lo.append(xf * v)
			hi.append(xf * (v + Vector3(0, h, 0)))
		for i in sides:
			var j := (i + 1) % sides
			var a := TAU * (i + 0.5) / sides
			solid.quad(lo[i], lo[j], hi[j], hi[i], _n(Vector3(cos(a), 0, sin(a))), col)
		if top:
			var up := _n(Vector3.UP)
			var i := 1
			while i + 1 < sides:
				solid.quad(hi[0], hi[i], hi[i + 1], hi[mini(i + 2, sides - 1)], up, col.lightened(0.05))
				i += 2

	func _box(buf: TerrainMesher.Buf, lo: Vector3, hi: Vector3, col: Color, faces: int) -> void:
		if faces & TerrainMesher.PX:
			buf.quad(xf * Vector3(hi.x, lo.y, lo.z), xf * Vector3(hi.x, hi.y, lo.z), xf * Vector3(hi.x, hi.y, hi.z), xf * Vector3(hi.x, lo.y, hi.z), _n(Vector3.RIGHT), col)
		if faces & TerrainMesher.NX:
			buf.quad(xf * Vector3(lo.x, lo.y, lo.z), xf * Vector3(lo.x, hi.y, lo.z), xf * Vector3(lo.x, hi.y, hi.z), xf * Vector3(lo.x, lo.y, hi.z), _n(Vector3.LEFT), col)
		if faces & TerrainMesher.PY:
			buf.quad(xf * Vector3(lo.x, hi.y, lo.z), xf * Vector3(hi.x, hi.y, lo.z), xf * Vector3(hi.x, hi.y, hi.z), xf * Vector3(lo.x, hi.y, hi.z), _n(Vector3.UP), col.lightened(0.04))
		if faces & TerrainMesher.NY:
			buf.quad(xf * Vector3(lo.x, lo.y, lo.z), xf * Vector3(hi.x, lo.y, lo.z), xf * Vector3(hi.x, lo.y, hi.z), xf * Vector3(lo.x, lo.y, hi.z), _n(Vector3.DOWN), col * 0.8)
		if faces & TerrainMesher.PZ:
			buf.quad(xf * Vector3(lo.x, lo.y, hi.z), xf * Vector3(hi.x, lo.y, hi.z), xf * Vector3(hi.x, hi.y, hi.z), xf * Vector3(lo.x, hi.y, hi.z), _n(Vector3.BACK), col)
		if faces & TerrainMesher.NZ:
			buf.quad(xf * Vector3(lo.x, lo.y, lo.z), xf * Vector3(hi.x, lo.y, lo.z), xf * Vector3(hi.x, hi.y, lo.z), xf * Vector3(lo.x, hi.y, lo.z), _n(Vector3.FORWARD), col)

	func _n(n: Vector3) -> Vector3:
		return (xf.basis * n).normalized()


static func info(shape: String) -> Dictionary:
	return INFO.get(shape, FLOOR_INFO)


static func has_shape(shape: String) -> bool:
	return shape in NAMES


const NAMES := ["chair", "stool", "armchair", "sofa", "bench", "park_bench", "table", "coffee_table",
		"desk", "workbench", "counter", "sink", "shelf", "bookcase", "cabinet_tall", "dresser", "locker",
		"filing_cabinet", "fridge", "glass_fridge", "chest_freezer", "appliance", "oven", "stove", "toilet",
		"bathtub", "shower", "bed", "crate", "crate_open", "cardboard_box", "trash_can", "recycle_bin",
		"dumpster", "plant", "flower", "hedge", "street_light", "pole", "sign", "mailbox", "boulder",
		"barricade", "panel_wall", "groundsheet", "roof_vent", "vent_pipe", "antenna", "dish", "solar",
		"tank", "machine", "vending", "arcade", "display_case", "glass_cabinet", "lamp", "coat_rack",
		"exercise", "punching_bag", "clothesline", "birdbath", "bulletin", "pallet", "console", "block",
		"trap_plate", "item_box", "item_book", "item_cloth", "item_bottle", "item_can", "item_long",
		"item_tool", "item_small", "item_bag", "item_corpse"]


## Builds `shape` with colours `main` (body), `accent` (CDDA colour: cushions, paint, flowers) and
## `leaf` (plants). `links` has bit d set when the neighbour in TerrainMesher.DIRS[d] joins this prop
## (seen in shape-local directions), `height` scales blocks, `rng` varies plants and clutter.
static func build(shape: String, b: Builder, main: Color, accent: Color, leaf: Color, links: int,
		height: float, rng: RandomNumberGenerator) -> void:
	match shape:
		"chair":
			_legs(b, 0.18, 0.18, 0.43, 0.04, main)
			b.box(Vector3(-0.21, 0.43, -0.21), Vector3(0.21, 0.48, 0.21), accent)
			for x: float in [-0.2, 0.16]:
				b.box(Vector3(x, 0.48, 0.17), Vector3(x + 0.04, 0.95, 0.21), main)
			b.box(Vector3(-0.2, 0.68, 0.17), Vector3(0.2, 0.9, 0.2), main)
		"stool":
			_legs(b, 0.13, 0.13, 0.6, 0.035, main)
			b.box(Vector3(-0.13, 0.25, -0.13), Vector3(0.13, 0.28, 0.13), main.darkened(0.15))
			b.cyl(Vector3(0, 0.6, 0), 0.18, 0.05, accent)
		"armchair":
			_legs(b, 0.36, 0.33, 0.1, 0.05, WOOD_DARK)
			b.box(Vector3(-0.4, 0.1, -0.36), Vector3(0.4, 0.42, 0.4), accent)
			b.box(Vector3(-0.27, 0.42, -0.34), Vector3(0.27, 0.52, 0.25), accent.lightened(0.08))
			b.box(Vector3(-0.4, 0.42, 0.25), Vector3(0.4, 0.98, 0.42), accent.darkened(0.08))
			for x: float in [-0.42, 0.28]:
				b.box(Vector3(x, 0.42, -0.36), Vector3(x + 0.14, 0.66, 0.26), accent.darkened(0.04))
		"sofa":
			var xl := links & X_LINKS
			_legs(b, 0.44, 0.36, 0.1, 0.05, WOOD_DARK, xl)
			_jbox(b, xl, Vector3(-0.5, 0.1, -0.38), Vector3(0.5, 0.42, 0.42), accent)
			b.box(Vector3(-0.47, 0.42, -0.36), Vector3(0.47, 0.53, 0.22), accent.lightened(0.08))
			_jbox(b, xl, Vector3(-0.5, 0.42, 0.22), Vector3(0.5, 0.95, 0.42), accent.darkened(0.08))
			if not (links & 8):
				b.box(Vector3(-0.5, 0.42, -0.38), Vector3(-0.38, 0.68, 0.24), accent.darkened(0.04))
			if not (links & 2):
				b.box(Vector3(0.38, 0.42, -0.38), Vector3(0.5, 0.68, 0.24), accent.darkened(0.04))
		"bench":
			var xl := links & X_LINKS
			for x: float in _ends(xl, -0.42, 0.36):
				b.box(Vector3(x, 0, -0.16), Vector3(x + 0.06, 0.42, 0.16), main.darkened(0.15))
			_slats(b, -0.48, 0.48, 0.42, 0.46, -0.18, 0.18, 3, main, xl)
		"park_bench":
			var xl := links & X_LINKS
			for x: float in _ends(xl, -0.44, 0.38):
				b.box(Vector3(x, 0, -0.2), Vector3(x + 0.06, 0.42, 0.18), METAL_DARK)
				b.box(Vector3(x, 0.42, 0.14), Vector3(x + 0.06, 0.9, 0.2), METAL_DARK)
			_slats(b, -0.5, 0.5, 0.42, 0.46, -0.2, 0.12, 3, main, xl)
			for y: float in [0.58, 0.76]:
				b.box(Vector3(-0.5, y, 0.17), Vector3(0.5, y + 0.1, 0.2), main, _unlinked(xl, ALL))
		"table":
			_legs(b, 0.38, 0.38, 0.72, 0.06, main.darkened(0.1), links)
			_jbox(b, links, Vector3(-0.4, 0.64, -0.4), Vector3(0.4, 0.72, 0.4), main.darkened(0.06))
			_jbox(b, links, Vector3(-0.46, 0.72, -0.46), Vector3(0.46, 0.77, 0.46), main, ALL)
		"coffee_table":
			_legs(b, 0.38, 0.26, 0.36, 0.05, main.darkened(0.1))
			b.box(Vector3(-0.42, 0.36, -0.3), Vector3(0.42, 0.41, 0.3), main, ALL)
			b.box(Vector3(-0.36, 0.1, -0.24), Vector3(0.36, 0.13, 0.24), main.darkened(0.1))
		"desk":
			var xl := links & X_LINKS
			b.box(Vector3(0.08, 0, -0.36), Vector3(0.46, 0.73, 0.36), main.darkened(0.08))
			for y: float in [0.22, 0.46]:
				b.box(Vector3(0.1, y, -0.37), Vector3(0.44, y + 0.012, -0.36), DARK)
			for y: float in [0.1, 0.34, 0.58]:
				b.box(Vector3(0.22, y, -0.38), Vector3(0.32, y + 0.025, -0.36), METAL)
			if not (xl & 8):   # a desk joined on its left shares the neighbour's drawers for support
				for z: float in [-0.36, 0.3]:
					b.box(Vector3(-0.46, 0, z), Vector3(-0.4, 0.73, z + 0.06), main.darkened(0.1))
			_jbox(b, xl, Vector3(-0.44, 0.1, 0.32), Vector3(0.08, 0.6, 0.35), main.darkened(0.12))
			_jbox(b, xl, Vector3(-0.48, 0.73, -0.38), Vector3(0.48, 0.77, 0.38), main, ALL)
		"workbench":
			var xl := links & X_LINKS
			_legs(b, 0.42, 0.34, 0.85, 0.07, main.darkened(0.12), xl)
			_jbox(b, xl, Vector3(-0.44, 0.18, -0.34), Vector3(0.44, 0.21, 0.34), main.darkened(0.1))
			_jbox(b, xl, Vector3(-0.48, 0.85, -0.4), Vector3(0.48, 0.93, 0.4), main, ALL)
			b.box(Vector3(0.28, 0.93, -0.42), Vector3(0.44, 1.02, -0.3), METAL_DARK)
		"counter":
			_counter(b, main, links)
		"sink":
			_counter(b, main, links)
			b.box(Vector3(-0.24, 0.93, -0.3), Vector3(0.24, 0.95, 0.12), METAL)
			b.box(Vector3(-0.19, 0.95, -0.25), Vector3(0.19, 0.951, 0.07), METAL_DARK, TerrainMesher.PY)
			b.box(Vector3(-0.02, 0.95, 0.2), Vector3(0.02, 1.15, 0.24), METAL)
			b.box(Vector3(-0.02, 1.11, 0.04), Vector3(0.02, 1.15, 0.24), METAL)
		"shelf":   # joined on +x: the neighbour's posts hold the shared end
			var xl := links & X_LINKS
			for x: float in [-0.48] if xl & 2 else [-0.48, 0.44]:
				for z: float in [-0.12, 0.43]:
					b.box(Vector3(x, 0, z), Vector3(x + 0.04, 1.8, z + 0.04), main.darkened(0.15))
			for y: float in [0.1, 0.55, 1.0, 1.45, 1.77]:
				_jbox(b, xl, Vector3(-0.48, y, -0.12), Vector3(0.48, y + 0.03, 0.47), main, ALL)
			_jbox(b, xl, Vector3(-0.46, 0.13, 0.45), Vector3(0.46, 1.77, 0.46), main.darkened(0.25))
		"bookcase":
			var xl := links & X_LINKS
			for x: float in [-0.48] if xl & 2 else [-0.48, 0.44]:
				b.box(Vector3(x, 0, -0.14), Vector3(x + 0.04, 1.9, 0.48), main)
			_jbox(b, xl, Vector3(-0.44, 0, 0.44), Vector3(0.44, 1.9, 0.48), main.darkened(0.2))
			_jbox(b, xl, Vector3(-0.5, 1.9, -0.16), Vector3(0.5, 1.95, 0.48), main.darkened(0.06), ALL)
			for y: float in [0.0, 0.5, 0.95, 1.4]:
				_jbox(b, xl, Vector3(-0.44, y, -0.12), Vector3(0.44, y + 0.08 if y == 0.0 else y + 0.03, 0.44), main)
		"cabinet_tall":
			_cabinet(b, Vector3(-0.46, 0, -0.3), Vector3(0.46, 2.0, 0.46), main, 2, 0)
		"dresser":
			_cabinet(b, Vector3(-0.46, 0, -0.28), Vector3(0.46, 1.0, 0.46), main, 0, 3)
		"locker":
			_cabinet(b, Vector3(-0.38, 0, -0.25), Vector3(0.38, 1.9, 0.45), main, 1, 0)
			for y: float in [1.6, 1.66, 1.72]:
				b.box(Vector3(-0.2, y, -0.26), Vector3(0.2, y + 0.02, -0.25), DARK)
		"filing_cabinet":
			_cabinet(b, Vector3(-0.25, 0, -0.32), Vector3(0.25, 1.3, 0.4), main, 0, 4)
		"fridge":
			_cabinet(b, Vector3(-0.42, 0, -0.3), Vector3(0.42, 1.85, 0.45), main, 0, 0)
			b.box(Vector3(-0.42, 1.25, -0.31), Vector3(0.42, 1.27, -0.3), DARK)
			for y: Array in [[0.7, 1.15], [1.35, 1.7]]:
				b.box(Vector3(0.3, y[0], -0.35), Vector3(0.34, y[1], -0.31), METAL)
		"glass_fridge":
			b.box(Vector3(-0.42, 0, -0.26), Vector3(0.42, 0.08, 0.45), main)
			b.box(Vector3(-0.42, 1.8, -0.26), Vector3(0.42, 1.95, 0.45), accent, ALL)
			for x: float in [-0.42, 0.38]:
				b.box(Vector3(x, 0.08, -0.26), Vector3(x + 0.04, 1.8, 0.45), main)
			b.box(Vector3(-0.38, 0.08, 0.41), Vector3(0.38, 1.8, 0.45), main.darkened(0.2))
			for y: float in [0.6, 1.1]:
				b.box(Vector3(-0.38, y - 0.02, -0.2), Vector3(0.38, y, 0.41), METAL)
			b.pane(Vector3(-0.38, 0.08, -0.26), Vector3(0.38, 1.8, -0.24))
			b.box(Vector3(0.3, 0.7, -0.3), Vector3(0.33, 1.3, -0.26), METAL)
		"chest_freezer":
			_cabinet(b, Vector3(-0.45, 0, -0.35), Vector3(0.45, 0.88, 0.42), main, 0, 0)
			b.box(Vector3(-0.45, 0.78, -0.36), Vector3(0.45, 0.8, -0.35), DARK)
			b.box(Vector3(-0.1, 0.7, -0.38), Vector3(0.1, 0.74, -0.35), METAL_DARK)
		"appliance":
			b.box(Vector3(-0.42, 0, -0.4), Vector3(0.42, 0.88, 0.42), main)
			b.box(Vector3(-0.42, 0.78, -0.41), Vector3(0.42, 0.88, -0.4), main.darkened(0.15))
			b.box(Vector3(0.18, 0.81, -0.42), Vector3(0.3, 0.85, -0.41), DARK)
			b.box(Vector3(-0.22, 0.24, -0.41), Vector3(0.22, 0.66, -0.4), METAL_DARK)
			b.box(Vector3(-0.16, 0.3, -0.42), Vector3(0.16, 0.6, -0.41), DARK.lightened(0.15))
		"oven":
			b.box(Vector3(-0.42, 0, -0.38), Vector3(0.42, 0.9, 0.42), main)
			b.box(Vector3(-0.32, 0.2, -0.39), Vector3(0.32, 0.6, -0.38), DARK)
			b.box(Vector3(-0.3, 0.66, -0.43), Vector3(0.3, 0.69, -0.39), METAL)
			for x: float in [-0.2, 0.2]:
				for z: float in [-0.18, 0.18]:
					b.cyl(Vector3(x, 0.9, z), 0.09, 0.015, DARK)
			b.box(Vector3(-0.42, 0.9, 0.36), Vector3(0.42, 1.05, 0.42), main.darkened(0.1))
		"stove":
			_legs(b, 0.3, 0.26, 0.15, 0.05, METAL_DARK)
			b.box(Vector3(-0.35, 0.15, -0.3), Vector3(0.35, 0.75, 0.35), main)
			b.box(Vector3(-0.2, 0.3, -0.31), Vector3(0.2, 0.6, -0.3), DARK)
			b.cyl(Vector3(0, 0.75, 0.15), 0.08, 2.25, METAL_DARK, 8, false)
		"toilet":
			b.cyl(Vector3(0, 0, -0.02), 0.13, 0.36, CERAMIC)
			b.box(Vector3(-0.19, 0.34, -0.32), Vector3(0.19, 0.42, 0.18), CERAMIC.darkened(0.04), ALL)
			b.box(Vector3(-0.2, 0.42, -0.32), Vector3(0.2, 0.44, 0.18), accent)
			b.box(Vector3(-0.22, 0.3, 0.24), Vector3(0.22, 0.78, 0.42), CERAMIC)
			b.box(Vector3(-0.23, 0.78, 0.23), Vector3(0.23, 0.81, 0.43), CERAMIC.darkened(0.05))
		"bathtub":   # walls on the outer sides only; floor and water run on into a joined tile
			_jbox(b, links, Vector3(-0.5, 0, -0.42), Vector3(0.5, 0.08, 0.45), main)
			if not (links & 1):
				_jbox(b, links & X_LINKS, Vector3(-0.5, 0, -0.42), Vector3(0.5, 0.55, -0.34), main)
			if not (links & 4):
				_jbox(b, links & X_LINKS, Vector3(-0.5, 0, 0.37), Vector3(0.5, 0.55, 0.45), main)
			if not (links & 8):
				_jbox(b, links & Z_LINKS, Vector3(-0.5, 0, -0.42), Vector3(-0.42, 0.55, 0.45), main)
			if not (links & 2):
				_jbox(b, links & Z_LINKS, Vector3(0.42, 0, -0.42), Vector3(0.5, 0.55, 0.45), main)
			_jbox(b, links, Vector3(-0.42, 0.08, -0.34), Vector3(0.42, 0.1, 0.37), BATH_WATER)
		"shower":
			b.box(Vector3(-0.48, 0, -0.48), Vector3(0.48, 0.08, 0.48), CERAMIC)
			b.box(Vector3(-0.03, 0.08, 0.42), Vector3(0.03, 2.0, 0.46), METAL)
			b.box(Vector3(-0.08, 1.95, 0.25), Vector3(0.08, 1.98, 0.46), METAL)
			b.pane(Vector3(-0.48, 0.08, -0.48), Vector3(0.48, 2.0, -0.46))
			b.pane(Vector3(-0.48, 0.08, -0.46), Vector3(-0.46, 2.0, 0.48))
		"bed":
			_bed(b, main, accent, links)
		"crate":
			b.box(Vector3(-0.4, 0, -0.4), Vector3(0.4, 0.75, 0.4), main)
			_battens(b, 0.4, 0.75, main.darkened(0.25))
		"crate_open":
			b.box(Vector3(-0.4, 0, -0.4), Vector3(0.4, 0.06, 0.4), main.darkened(0.1))
			for s: Array in [[Vector3(-0.4, 0, -0.4), Vector3(0.4, 0.7, -0.36)], [Vector3(-0.4, 0, 0.36), Vector3(0.4, 0.7, 0.4)],
					[Vector3(-0.4, 0, -0.36), Vector3(-0.36, 0.7, 0.36)], [Vector3(0.36, 0, -0.36), Vector3(0.4, 0.7, 0.36)]]:
				b.box(s[0], s[1], main, ALL & ~NY)
			_battens(b, 0.4, 0.7, main.darkened(0.25))
		"cardboard_box":
			b.box(Vector3(-0.45, 0, -0.45), Vector3(0.45, 0.9, 0.45), main)
			b.box(Vector3(-0.06, 0.9, -0.46), Vector3(0.06, 0.905, 0.46), main.lightened(0.25), ALL & ~NY)
		"trash_can":
			b.cyl(Vector3.ZERO, 0.24, 0.75, accent)
			b.cyl(Vector3(0, 0.75, 0), 0.27, 0.05, accent.darkened(0.15))
			b.box(Vector3(-0.06, 0.8, -0.02), Vector3(0.06, 0.84, 0.02), METAL_DARK)
		"recycle_bin":
			b.box(Vector3(-0.3, 0, -0.32), Vector3(0.3, 0.9, 0.3), accent)
			b.box(Vector3(-0.32, 0.9, -0.34), Vector3(0.32, 0.95, 0.32), accent.darkened(0.15), ALL)
		"dumpster":
			for x: float in [-0.42, 0.34]:
				for z: float in [-0.36, 0.32]:
					b.box(Vector3(x, 0, z), Vector3(x + 0.08, 0.15, z + 0.08), DARK)
			b.box(Vector3(-0.5, 0.15, -0.42), Vector3(0.5, 1.2, 0.45), accent)
			b.box(Vector3(-0.52, 1.0, -0.44), Vector3(0.52, 1.06, 0.47), accent.darkened(0.15))
			b.box(Vector3(-0.5, 1.2, -0.42), Vector3(0.5, 1.26, 0.45), DARK.lightened(0.1), ALL)
		"plant":
			b.cyl(Vector3.ZERO, 0.16, 0.3, TERRACOTTA)
			b.cyl(Vector3(0, 0.3, 0), 0.18, 0.04, TERRACOTTA.darkened(0.1))
			_foliage(b, leaf, accent, 0.32, 0.55, 0.22, rng, 4)
		"flower":
			for i in 3:
				var p := Vector3(rng.randf_range(-0.3, 0.3), 0, rng.randf_range(-0.3, 0.3))
				var h := rng.randf_range(0.22, 0.42)
				b.box(p + Vector3(-0.008, 0, -0.008), p + Vector3(0.008, h, 0.008), LEAF)
				b.box(p + Vector3(-0.05, h * 0.4, -0.012), p + Vector3(0.05, h * 0.4 + 0.012, 0.012), LEAF)
				b.box(p + Vector3(-0.035, h, -0.035), p + Vector3(0.035, h + 0.05, 0.035), accent, ALL)
		"hedge":
			b.box(Vector3(-0.48, 0, -0.42), Vector3(0.48, 0.95, 0.42), leaf)
			_foliage(b, leaf.lightened(0.06), leaf, 0.75, 0.35, 0.35, rng, 3)
		"street_light":
			b.cyl(Vector3.ZERO, 0.13, 0.4, METAL_DARK)
			b.cyl(Vector3.ZERO, 0.07, 5.0, METAL_DARK, 8, false)
			b.box(Vector3(-0.03, 4.85, -1.3), Vector3(0.03, 4.95, 0.05), METAL_DARK, ALL)
			b.box(Vector3(-0.14, 4.74, -1.55), Vector3(0.14, 4.88, -1.05), METAL_DARK, ALL)
			b.box(Vector3(-0.11, 4.73, -1.5), Vector3(0.11, 4.74, -1.1), LAMP, ALL)
		"pole":
			b.cyl(Vector3.ZERO, 0.12, 7.0, main, 8)
			b.box(Vector3(-0.8, 6.4, -0.05), Vector3(0.8, 6.52, 0.05), main.darkened(0.1), ALL)
		"sign":
			for x: float in [-0.3, 0.26]:
				b.box(Vector3(x, 0, -0.02), Vector3(x + 0.04, 1.1, 0.02), WOOD_DARK)
			b.box(Vector3(-0.42, 1.05, -0.03), Vector3(0.42, 1.6, 0.03), accent, ALL)
			b.box(Vector3(-0.36, 1.12, -0.035), Vector3(0.36, 1.53, -0.03), LINEN, ALL)
		"mailbox":
			b.box(Vector3(-0.04, 0, -0.04), Vector3(0.04, 1.0, 0.04), WOOD_DARK)
			b.box(Vector3(-0.12, 1.0, -0.26), Vector3(0.12, 1.22, 0.2), main, ALL)
			b.box(Vector3(0.12, 1.1, 0.0), Vector3(0.14, 1.3, 0.04), Color(0.7, 0.15, 0.12), ALL)
		"boulder":
			var c := main.darkened(0.05)
			b.box(Vector3(-0.32, 0, -0.28), Vector3(0.3, 0.4 * height, 0.3), c)
			b.box(Vector3(-0.22, 0.2 * height, -0.2), Vector3(0.24, 0.55 * height, 0.22), c.lightened(0.05))
			b.box(Vector3(0.05, 0, -0.38), Vector3(0.38, 0.28 * height, 0.0), c.darkened(0.06))
		"barricade":
			for x: float in [-0.42, 0.36]:
				b.box(Vector3(x, 0, -0.2), Vector3(x + 0.06, 1.0, -0.14), WOOD)
				b.box(Vector3(x, 0, 0.14), Vector3(x + 0.06, 1.0, 0.2), WOOD)
			for y: float in [0.45, 0.8]:
				for i in 5:
					var x0 := -0.5 + i * 0.2
					b.box(Vector3(x0, y, -0.03), Vector3(x0 + 0.2, y + 0.16, 0.03), accent if i % 2 == 0 else DARK, ALL)
		"panel_wall":
			b.box(Vector3(-0.04, 0, -0.04), Vector3(0.04, 2.3, 0.04), WOOD_DARK)
			var any := false
			for d in 4:
				if links & (1 << d):
					any = true
					_panel_toward(b, d, 2.2, main)
			if not any:
				_panel_toward(b, 1, 2.2, main)
				_panel_toward(b, 3, 2.2, main)
		"groundsheet":
			b.box(Vector3(-0.5, 0, -0.5), Vector3(0.5, 0.02, 0.5), accent, TerrainMesher.PY)
		"roof_vent":
			b.cyl(Vector3.ZERO, 0.14, 0.3, METAL)
			b.cyl(Vector3(0, 0.3, 0), 0.24, 0.3, METAL.lightened(0.1))
			b.cyl(Vector3(0, 0.6, 0), 0.16, 0.06, METAL)
		"vent_pipe":
			b.cyl(Vector3.ZERO, 0.06, 0.9, main)
			b.cyl(Vector3(0, 0.9, 0), 0.1, 0.06, main.darkened(0.1))
		"antenna":
			b.box(Vector3(-0.02, 0, -0.02), Vector3(0.02, 2.4, 0.02), METAL)
			for i in 4:
				var w := 0.5 - i * 0.1
				b.box(Vector3(-w, 1.6 + i * 0.22, -0.01), Vector3(w, 1.62 + i * 0.22, 0.01), METAL, ALL)
		"dish":
			b.box(Vector3(-0.03, 0, -0.03), Vector3(0.03, 0.55, 0.03), METAL_DARK)
			var save := b.xf
			b.xf = b.xf * Transform3D(Basis(Vector3.RIGHT, 0.7), Vector3(0, 0.5, 0))
			b.cyl(Vector3.ZERO, 0.32, 0.04, LINEN)
			b.xf = save
		"solar":
			for z: float in [-0.3, 0.25]:
				b.box(Vector3(-0.4, 0, z), Vector3(-0.36, 0.3 + (z + 0.3) * 0.8, z + 0.05), METAL)
				b.box(Vector3(0.36, 0, z), Vector3(0.4, 0.3 + (z + 0.3) * 0.8, z + 0.05), METAL)
			var save := b.xf
			b.xf = b.xf * Transform3D(Basis(Vector3.RIGHT, -0.62), Vector3(0, 0.52, 0))
			b.box(Vector3(-0.46, -0.02, -0.38), Vector3(0.46, 0.02, 0.38), Color(0.14, 0.18, 0.32), ALL)
			for x: float in [-0.15, 0.15]:
				b.box(Vector3(x - 0.005, 0.02, -0.38), Vector3(x + 0.005, 0.025, 0.38), METAL, TerrainMesher.PY)
			b.xf = save
		"tank":
			b.cyl(Vector3.ZERO, 0.38, 1.7, main)
			for y: float in [0.3, 1.3]:
				b.cyl(Vector3(0, y, 0), 0.39, 0.05, main.darkened(0.12), 8, false)
			b.cyl(Vector3(0, 1.7, 0), 0.05, 0.25, METAL_DARK)
		"machine":
			b.box(Vector3(-0.42, 0, -0.36), Vector3(0.42, 1.1 * height, 0.42), main)
			b.box(Vector3(-0.3, 0.55 * height, -0.37), Vector3(0.3, 0.95 * height, -0.36), accent)
			for i in 4:
				var y := (0.12 + i * 0.08) * height
				b.box(Vector3(-0.3, y, -0.37), Vector3(0.3, y + 0.025, -0.36), DARK)
			b.box(Vector3(-0.44, 1.1 * height, -0.38), Vector3(0.44, 1.14 * height, 0.44), main.darkened(0.12), ALL)
		"vending":
			b.box(Vector3(-0.45, 0, -0.32), Vector3(0.45, 1.9, 0.45), accent)
			b.box(Vector3(-0.4, 0.62, -0.33), Vector3(0.18, 1.8, -0.32), DARK)
			b.pane(Vector3(-0.4, 0.62, -0.35), Vector3(0.18, 1.8, -0.33))
			b.box(Vector3(0.22, 1.1, -0.34), Vector3(0.4, 1.6, -0.32), METAL_DARK)
			b.box(Vector3(-0.4, 0.15, -0.34), Vector3(0.18, 0.45, -0.32), DARK)
		"arcade":
			b.box(Vector3(-0.34, 0, -0.28), Vector3(0.34, 1.75, 0.4), accent)
			b.box(Vector3(-0.27, 1.05, -0.29), Vector3(0.27, 1.5, -0.28), Color(0.1, 0.2, 0.3))
			b.box(Vector3(-0.34, 0.88, -0.45), Vector3(0.34, 0.98, -0.28), DARK, ALL)
			b.box(Vector3(-0.36, 1.6, -0.3), Vector3(0.36, 1.75, -0.28), LAMP)
		"display_case":
			b.box(Vector3(-0.45, 0, -0.4), Vector3(0.45, 0.85, 0.45), main)
			b.box(Vector3(-0.45, 0.83, -0.4), Vector3(0.45, 0.86, 0.45), main.darkened(0.1), TerrainMesher.PY)
			b.pane(Vector3(-0.45, 0.86, -0.4), Vector3(0.45, 1.3, 0.45))
		"glass_cabinet":
			b.box(Vector3(-0.45, 0, -0.14), Vector3(0.45, 0.3, 0.45), main)
			b.box(Vector3(-0.45, 1.8, -0.14), Vector3(0.45, 1.86, 0.45), main, ALL)
			b.box(Vector3(-0.43, 0.3, 0.41), Vector3(0.43, 1.8, 0.45), main.darkened(0.2))
			for y: float in [0.78, 1.28]:
				b.pane(Vector3(-0.43, y - 0.01, -0.12), Vector3(0.43, y + 0.01, 0.41))
			b.pane(Vector3(-0.45, 0.3, -0.14), Vector3(0.45, 1.8, -0.12))
		"lamp":
			b.cyl(Vector3.ZERO, 0.15, 0.04, METAL_DARK)
			b.box(Vector3(-0.015, 0.04, -0.015), Vector3(0.015, 1.5, 0.015), METAL_DARK)
			b.cyl(Vector3(0, 1.42, 0), 0.2, 0.26, LAMP.darkened(0.08))
		"coat_rack":
			b.box(Vector3(-0.2, 0, -0.03), Vector3(0.2, 0.04, 0.03), main.darkened(0.1))
			b.box(Vector3(-0.03, 0, -0.2), Vector3(0.03, 0.04, 0.2), main.darkened(0.1))
			b.box(Vector3(-0.025, 0, -0.025), Vector3(0.025, 1.8, 0.025), main)
			for d in 4:
				var v := Vector3(TerrainMesher.DIRS[d].x, 0, TerrainMesher.DIRS[d].y) * 0.12
				b.box(Vector3(-0.012, 1.62, -0.012) + v * 0.5, Vector3(0.012, 1.66, 0.012) + v, main, ALL)
		"exercise":
			b.box(Vector3(-0.12, 0, -0.45), Vector3(0.12, 0.45, 0.2), WOOD_DARK)
			b.box(Vector3(-0.14, 0.45, -0.45), Vector3(0.14, 0.52, 0.2), accent.darkened(0.3))
			for x: float in [-0.4, 0.34]:
				b.box(Vector3(x, 0, 0.3), Vector3(x + 0.06, 1.9, 0.36), METAL_DARK)
			b.box(Vector3(-0.4, 1.84, 0.3), Vector3(0.4, 1.9, 0.36), METAL_DARK)
			b.box(Vector3(-0.15, 0, 0.38), Vector3(0.15, 0.6, 0.46), DARK)
		"punching_bag":
			b.box(Vector3(-0.01, 1.9, -0.01), Vector3(0.01, 3.0, 0.01), METAL)
			b.cyl(Vector3(0, 0.85, 0), 0.18, 1.05, main)
		"clothesline":
			b.box(Vector3(-0.025, 0, -0.025), Vector3(0.025, 1.9, 0.025), METAL)
			for d in 4:
				var v := Vector3(TerrainMesher.DIRS[d].x, 0, TerrainMesher.DIRS[d].y)
				var lo := Vector3(minf(v.x, 0) * 0.48 - 0.01, 1.82, minf(v.z, 0) * 0.48 - 0.01)
				var hi := Vector3(maxf(v.x, 0) * 0.48 + 0.01, 1.85, maxf(v.z, 0) * 0.48 + 0.01)
				b.box(lo, hi, METAL, ALL)
		"birdbath":
			b.cyl(Vector3.ZERO, 0.14, 0.05, main)
			b.cyl(Vector3.ZERO, 0.07, 0.7, main)
			b.cyl(Vector3(0, 0.7, 0), 0.3, 0.1, main)
			b.cyl(Vector3(0, 0.8, 0), 0.25, 0.005, Color(0.3, 0.42, 0.55))
		"bulletin":
			for x: float in [-0.44, 0.4]:
				b.box(Vector3(x, 0, -0.03), Vector3(x + 0.04, 1.85, 0.03), WOOD_DARK)
			b.box(Vector3(-0.42, 0.9, -0.02), Vector3(0.42, 1.8, 0.03), Color(0.65, 0.5, 0.32), ALL)
			for i in 4:
				var x := rng.randf_range(-0.36, 0.22)
				var y := rng.randf_range(0.95, 1.6)
				b.box(Vector3(x, y, -0.025), Vector3(x + 0.13, y + 0.16, -0.02), LINEN, ALL)
		"pallet":
			for x: float in [-0.45, -0.05, 0.35]:
				b.box(Vector3(x, 0, -0.45), Vector3(x + 0.1, 0.1, 0.45), WOOD_DARK)
			b.box(Vector3(-0.45, 0.1, -0.45), Vector3(0.45, 0.13, 0.45), WOOD, ALL)
			for layer in 2:
				for i in 3:
					var z := -0.42 + i * 0.28
					var y := 0.13 + layer * 0.16
					b.box(Vector3(-0.4, y, z), Vector3(0.4, y + 0.15, z + 0.26), accent.darkened(0.05 * ((i + layer) % 2)), ALL & ~NY)
		"console":
			b.box(Vector3(-0.45, 0, -0.3), Vector3(0.45, 0.8, 0.42), main)
			var save := b.xf
			b.xf = b.xf * Transform3D(Basis(Vector3.RIGHT, -0.5), Vector3(0, 0.8, -0.05))
			b.box(Vector3(-0.4, 0, -0.25), Vector3(0.4, 0.05, 0.2), DARK, ALL)
			b.xf = save
			b.box(Vector3(-0.3, 0.9, 0.2), Vector3(0.3, 1.3, 0.3), DARK.lightened(0.1))
		"trap_plate":
			b.box(Vector3(-0.3, 0, -0.3), Vector3(0.3, 0.03, 0.3), accent, ALL & ~NY)
			b.box(Vector3(-0.32, 0.03, -0.03), Vector3(0.32, 0.05, 0.03), DARK, ALL & ~NY)
			b.box(Vector3(-0.03, 0.03, -0.32), Vector3(0.03, 0.05, 0.32), DARK, ALL & ~NY)
		"item_box":
			b.box(Vector3(-0.5, 0, -0.5), Vector3(0.5, 0.9, 0.5), main)
			b.box(Vector3(-0.51, 0.35, -0.51), Vector3(0.51, 0.6, 0.51), main.lightened(0.2), ALL & ~(NY | TerrainMesher.PY))
		"item_book":
			b.box(Vector3(-0.5, 0, -0.38), Vector3(0.5, 0.06, 0.38), main, ALL)
			b.box(Vector3(-0.46, 0.06, -0.36), Vector3(0.5, 0.26, 0.36), LINEN)
			b.box(Vector3(-0.5, 0.26, -0.38), Vector3(0.5, 0.32, 0.38), main, ALL)
			b.box(Vector3(-0.5, 0.06, -0.38), Vector3(-0.46, 0.26, 0.38), main.darkened(0.1))
		"item_cloth":
			b.box(Vector3(-0.5, 0, -0.4), Vector3(0.5, 0.18, 0.4), main)
			b.box(Vector3(-0.48, 0.18, -0.38), Vector3(0.2, 0.28, 0.38), main.lightened(0.08))
		"item_bottle":
			b.cyl(Vector3.ZERO, 0.24, 0.75, main)
			b.cyl(Vector3(0, 0.75, 0), 0.1, 0.25, main.lightened(0.1))
			b.cyl(Vector3(0, 1.0, 0), 0.11, 0.08, DARK.lightened(0.2))
		"item_can":
			b.cyl(Vector3.ZERO, 0.36, 0.85, main)
			b.cyl(Vector3(0, 0.85, 0), 0.37, 0.04, METAL)
			b.cyl(Vector3(0, 0.3, 0), 0.365, 0.25, main.lightened(0.25), 8, false)
		"item_long":
			b.box(Vector3(-0.09, 0, -1.4), Vector3(0.09, 0.14, 0.6), main)
			b.box(Vector3(-0.1, 0, 0.6), Vector3(0.1, 0.22, 1.3), main.darkened(0.25))
		"item_tool":
			b.box(Vector3(-0.08, 0, -0.9), Vector3(0.08, 0.12, 0.3), WOOD)
			b.box(Vector3(-0.3, 0, 0.3), Vector3(0.3, 0.2, 0.6), main)
		"item_small":
			b.box(Vector3(-0.5, 0, -0.35), Vector3(0.0, 0.6, 0.15), main)
			b.box(Vector3(0.05, 0, -0.2), Vector3(0.5, 0.5, 0.3), main.darkened(0.12))
			b.box(Vector3(-0.3, 0, 0.18), Vector3(0.15, 0.45, 0.5), main.lightened(0.1))
		"item_bag":
			b.box(Vector3(-0.45, 0, -0.35), Vector3(0.45, 0.7, 0.35), main)
			b.box(Vector3(-0.15, 0.7, -0.12), Vector3(0.15, 0.85, 0.12), main.darkened(0.15))
		"item_corpse":
			b.box(Vector3(-0.5, 0, -0.28), Vector3(0.5, 0.3, 0.28), main.darkened(0.2))
			b.box(Vector3(0.25, 0, -0.18), Vector3(0.62, 0.24, 0.18), main.darkened(0.3))
		_:   # "block" and anything unknown
			var h := clampf(height, 0.2, 2.5)
			b.box(Vector3(-0.4, 0, -0.4), Vector3(0.4, h - 0.05, 0.4), main)
			b.box(Vector3(-0.42, h - 0.05, -0.42), Vector3(0.42, h, 0.42), main.darkened(0.15), ALL)


## Four legs at (±x, ±z), except at corners on a linked side (only a joined piece's outer corners).
static func _legs(b: Builder, x: float, z: float, h: float, t: float, col: Color, links := 0) -> void:
	for sx: float in [-1.0, 1.0]:
		if links & (2 if sx > 0 else 8):
			continue
		for sz: float in [-1.0, 1.0]:
			if links & (4 if sz > 0 else 1):
				continue
			var c := Vector3(sx * x, 0, sz * z)
			b.box(c - Vector3(t / 2, 0, t / 2), c + Vector3(t / 2, h, t / 2), col)


## The x of a bench's end supports: the low (-x) and high (+x) one, except on a linked side.
static func _ends(xl: int, lo: float, hi: float) -> Array:
	var out := []
	if not (xl & 8):
		out.append(lo)
	if not (xl & 2):
		out.append(hi)
	return out


static func _slats(b: Builder, x0: float, x1: float, y0: float, y1: float, z0: float, z1: float, n: int, col: Color,
		links := 0) -> void:
	var w := (z1 - z0) / n
	for i in n:
		_jbox(b, links, Vector3(x0, y0, z0 + i * w), Vector3(x1, y1, z0 + (i + 0.8) * w), col.darkened(0.05 * (i % 2)), ALL)


## A box stretched to the tile edge on linked sides, without faces there (no seam inside a joined
## piece). `links` in shape-local bits (1 front -z, 2 +x, 4 back +z, 8 -x); mask it to stretch one axis.
static func _jbox(b: Builder, links: int, lo: Vector3, hi: Vector3, col: Color, faces := SIDES) -> void:
	var l := Vector3(-0.5 if links & 8 else lo.x, lo.y, -0.5 if links & 1 else lo.z)
	var h := Vector3(0.5 if links & 2 else hi.x, hi.y, 0.5 if links & 4 else hi.z)
	b.box(l, h, col, _unlinked(links, faces))


## `faces` without the sides that touch a linked neighbour.
static func _unlinked(links: int, faces: int) -> int:
	if links & 1:
		faces &= ~TerrainMesher.NZ
	if links & 2:
		faces &= ~TerrainMesher.PX
	if links & 4:
		faces &= ~TerrainMesher.PZ
	if links & 8:
		faces &= ~TerrainMesher.NX
	return faces


## A bed tile (see the class notes): frame, mattress and blanket run on into joined tiles, legs at the
## bed's outer corners, headboard and pillow on the head row (nothing joined behind), the blanket hanging
## over the foot end on the foot row (nothing joined in front).
static func _bed(b: Builder, main: Color, accent: Color, links: int) -> void:
	var xl := links & X_LINKS
	_legs(b, 0.44, 0.44, 0.15, 0.06, main.darkened(0.1), links)
	_jbox(b, links, Vector3(-0.48, 0.15, -0.48), Vector3(0.48, 0.32, 0.48), main)
	_jbox(b, links, Vector3(-0.46, 0.32, -0.46), Vector3(0.46, 0.52, 0.46), LINEN)
	var head := not (links & 4)
	_jbox(b, links, Vector3(-0.47, 0.5, -0.47), Vector3(0.47, 0.58, 0.22 if head else 0.47), accent)
	if not (links & 1):
		_jbox(b, xl, Vector3(-0.47, 0.3, -0.49), Vector3(0.47, 0.58, -0.47), accent.darkened(0.06))
	if head:
		b.box(Vector3(-0.3, 0.52, 0.26), Vector3(0.3, 0.64, 0.42), PILLOW)
		_jbox(b, xl, Vector3(-0.48, 0, 0.42), Vector3(0.48, 1.0, 0.5), main.darkened(0.08), ALL & ~NY)


## A kitchen counter run: cabinets with doors, kick plate and a stone top. Joined neighbours (links)
## share one top that runs on to them (round an L corner too) and lose the end panels' seams.
static func _counter(b: Builder, main: Color, links: int) -> void:
	var xl := links & X_LINKS
	_jbox(b, xl, Vector3(-0.5, 0, -0.34), Vector3(0.5, 0.08, 0.5), DARK.lightened(0.1))
	_jbox(b, xl, Vector3(-0.5, 0.08, -0.42), Vector3(0.5, 0.88, 0.5), main)
	b.box(Vector3(-0.005, 0.12, -0.425), Vector3(0.005, 0.84, -0.42), main.darkened(0.3))
	for x: float in [-0.08, 0.06]:
		b.box(Vector3(x, 0.66, -0.44), Vector3(x + 0.02, 0.78, -0.42), METAL)
	_jbox(b, links, Vector3(-0.5, 0.88, -0.47), Vector3(0.5, 0.93, 0.5), STONE_TOP, ALL)


## A closed cabinet: body, `doors` vertical door seams (1: a single door with a handle on the right,
## 2: a pair), `drawers` horizontal drawer fronts, and a top trim.
static func _cabinet(b: Builder, lo: Vector3, hi: Vector3, main: Color, doors: int, drawers: int) -> void:
	b.box(lo, hi - Vector3(0, 0.04, 0), main)
	b.box(Vector3(lo.x - 0.015, hi.y - 0.04, lo.z - 0.015), Vector3(hi.x + 0.015, hi.y, hi.z), main.darkened(0.12), ALL)
	var z := lo.z
	if doors == 2:
		b.box(Vector3(-0.005, lo.y + 0.05, z - 0.005), Vector3(0.005, hi.y - 0.08, z), main.darkened(0.3))
		for x: float in [-0.07, 0.05]:
			b.box(Vector3(x, (lo.y + hi.y) * 0.5 - 0.1, z - 0.03), Vector3(x + 0.02, (lo.y + hi.y) * 0.5 + 0.1, z), METAL)
	elif doors == 1:
		b.box(Vector3(hi.x - 0.12, (lo.y + hi.y) * 0.5 - 0.08, z - 0.03), Vector3(hi.x - 0.1, (lo.y + hi.y) * 0.5 + 0.08, z), METAL)
	if drawers > 0:
		var step := (hi.y - lo.y - 0.1) / drawers
		for i in drawers:
			var y := lo.y + 0.05 + i * step
			b.box(Vector3(lo.x + 0.03, y + step - 0.01, z - 0.005), Vector3(hi.x - 0.03, y + step, z), main.darkened(0.3))
			b.box(Vector3(-0.06, y + step * 0.5, z - 0.03), Vector3(0.06, y + step * 0.5 + 0.025, z), METAL)


static func _battens(b: Builder, r: float, h: float, col: Color) -> void:
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var c := Vector3(sx * (r - 0.03), 0, sz * (r - 0.03))
			b.box(c - Vector3(0.035, 0, 0.035), c + Vector3(0.035, h + 0.01, 0.035), col)


static func _foliage(b: Builder, col: Color, col2: Color, y0: float, size: float, spread: float,
		rng: RandomNumberGenerator, n: int) -> void:
	for i in n:
		var s := size * rng.randf_range(0.55, 0.85)
		var c := Vector3(rng.randf_range(-spread, spread) * 0.6, y0 + rng.randf_range(0.0, size * 0.6), rng.randf_range(-spread, spread) * 0.6)
		b.box(c - Vector3(s / 2, 0, s / 2), c + Vector3(s / 2, s * 0.8, s / 2), col if i % 3 != 2 else col.lerp(col2, 0.5), ALL)


static func _panel_toward(b: Builder, d: int, h: float, col: Color) -> void:
	var v := Vector3(TerrainMesher.DIRS[d].x, 0, TerrainMesher.DIRS[d].y) * 0.5
	var t := 0.025
	var lo := Vector3(minf(v.x, 0) - (t if v.x == 0 else 0.0), 0, minf(v.z, 0) - (t if v.z == 0 else 0.0))
	var hi := Vector3(maxf(v.x, 0) + (t if v.x == 0 else 0.0), h, maxf(v.z, 0) + (t if v.z == 0 else 0.0))
	b.box(lo, hi, col, ALL)
