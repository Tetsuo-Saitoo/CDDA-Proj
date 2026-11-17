class_name GunGrime
extends RefCounted
## Gun fouling as grime: one mapping and one look wherever a gun shows it. CDDA's item var `dirt` (0..DIRT_MAX; a gun
## that doesn't foul sends none, read as -1) becomes grime 0..1 (grime_for) for:
## - the held gun's procedural parts (WeaponViewmodel, VrGun: grime.gdshader replaces their plain materials);
## - any gun model (apply(): a grime shell over each of its meshes, grime_overlay.gdshader; the model's own materials
##   and material_overlay are left alone): a .glb gun, a prop placeholder lying in the world;
## - a gun's icon (lead-ui): grime_for, or step_for for CDDA's own fouling symbol (one step per STEP).
## Both shaders share grime.gdshaderinc, so the film and soot look the same at the same value.

const DIRT_MAX := 10000
const STEP := 2000                  # CDDA's fouling symbol (item::dirt_symbol): one step per 2000, 5 at most
const MAX_MESHES := 64              # meshes under one model that get a shell (a gun has a handful)
const MAX_DEPTH := 8                # how deep apply() looks under the model's root
const SHELL := "GunGrime"           # the shell's node name, a child of the mesh it covers
const OVERLAY_SHADER := preload("res://scripts/combat/grime_overlay.gdshader")


## CDDA's `dirt` as grime 0..1; anything outside 0..DIRT_MAX is clamped (none, -1: clean).
static func grime_for(dirt: int) -> float:
	return float(clampi(dirt, 0, DIRT_MAX)) / DIRT_MAX


## CDDA's fouling symbol step for `dirt`: 0 (no symbol) .. 5.
static func step_for(dirt: int) -> int:
	return clampi(dirt, 0, DIRT_MAX) / STEP


## Grime `level` (0..1; not finite counts as 0) over the meshes under `root` (itself included; at most MAX_MESHES,
## MAX_DEPTH deep): each gets a shell sized to its box, or has its shell's level changed. Level 0 removes the shells (a
## clean gun draws nothing more). Meshes added later get one on the next call. Returns how many meshes wear one.
static func apply(root: Node, level: float) -> int:
	var g := clampf(level, 0.0, 1.0) if is_finite(level) else 0.0
	var n := 0
	for mi: MeshInstance3D in meshes(root):
		var shell := mi.get_node_or_null(SHELL) as MeshInstance3D
		if g <= 0.0:
			if shell != null:
				mi.remove_child(shell)
				shell.queue_free()
			continue
		if shell == null:
			shell = _shell_for(mi)
			if shell == null:
				continue
			mi.add_child(shell)
		(shell.material_override as ShaderMaterial).set_shader_parameter("grime", g)
		n += 1
	return n


## The grime a model shows (apply's level; 0 when it wears no shell).
static func level_of(root: Node) -> float:
	for mi: MeshInstance3D in meshes(root):
		var shell := mi.get_node_or_null(SHELL) as MeshInstance3D
		var m := shell.material_override as ShaderMaterial if shell != null else null
		if m != null:
			return float(m.get_shader_parameter("grime"))
	return 0.0


## The meshes under `root` (itself included) that can wear a shell, depth first: at most MAX_MESHES, MAX_DEPTH deep;
## shells, skinned meshes and empty ones left out.
static func meshes(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root != null:
		_collect(root, 0, out)
	return out


static func _collect(n: Node, depth: int, out: Array[MeshInstance3D]) -> void:
	if out.size() >= MAX_MESHES or n.name == SHELL:
		return
	var mi := n as MeshInstance3D
	if mi != null and mi.mesh != null and mi.skin == null:
		out.append(mi)
	if depth >= MAX_DEPTH:
		return
	for c: Node in n.get_children():
		_collect(c, depth + 1, out)
		if out.size() >= MAX_MESHES:
			return


## A shell for `mi`: the same mesh with the grime shader, sized to the mesh's box; null for a mesh with no size.
static func _shell_for(mi: MeshInstance3D) -> MeshInstance3D:
	var box := mi.mesh.get_aabb()
	if not (box.size.is_finite() and box.position.is_finite()) or box.size == Vector3.ZERO:
		return null
	var m := ShaderMaterial.new()
	m.shader = OVERLAY_SHADER
	m.set_shader_parameter("box_centre", box.get_center())
	m.set_shader_parameter("half_extents", box.size / 2.0)
	var shell := MeshInstance3D.new()
	shell.name = SHELL
	shell.mesh = mi.mesh
	shell.material_override = m
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shell.layers = mi.layers
	return shell
