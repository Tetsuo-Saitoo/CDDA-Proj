class_name FieldView
extends Node3D
## Fire, sparks, smoke and gas: CDDA's fields (snapshot `fields`, seen tiles only) that hang in the air. Ground
## fields (blood, gibs, acid, slime...) are GoreView's. Fire draws as flickering flames, electricity, plasma and
## lasers as bright flecks, smoke and gases as soft drifting puffs in the gas's colour, bee swarms as dark
## specks; more and denser with intensity (1..3). Invisible fields (hot and cold air, markers) and vents (the
## emitters; what they emit is its own field) are skipped. One MultiMesh per look (four draws at most), every
## instance a camera-facing quad from one small shader per look: billboards use the main camera's inverse view,
## so both VR eyes see the same quad. Rebuilt per snapshot, deterministic per square, MAX_PER_LOOK instances
## per look at most.

const MAX_PER_LOOK := 2048
enum Look { FLAME, SPARK, GAS, SWARM }
## field id -> [look, colour]; a gas colour's alpha is its density at intensity 3.
const KINDS := {
	"fd_fire": [Look.FLAME, Color(1.0, 0.5, 0.12)],
	"fd_flame_burst": [Look.FLAME, Color(1.0, 0.58, 0.2)],
	"fd_incendiary": [Look.FLAME, Color(1.0, 0.42, 0.08)],
	"fd_electricity": [Look.SPARK, Color(0.6, 0.8, 1.0)],
	"fd_plasma": [Look.SPARK, Color(0.85, 0.4, 1.0)],
	"fd_laser": [Look.SPARK, Color(1.0, 0.2, 0.15)],
	"fd_dazzling": [Look.SPARK, Color(1.0, 1.0, 0.85)],
	"fd_smoke": [Look.GAS, Color(0.24, 0.24, 0.25, 0.85)],
	"fd_cigsmoke": [Look.GAS, Color(0.72, 0.72, 0.74, 0.3)],
	"fd_weedsmoke": [Look.GAS, Color(0.66, 0.7, 0.62, 0.35)],
	"fd_cracksmoke": [Look.GAS, Color(0.72, 0.7, 0.7, 0.35)],
	"fd_methsmoke": [Look.GAS, Color(0.76, 0.76, 0.8, 0.35)],
	"fd_toxic_gas": [Look.GAS, Color(0.55, 0.7, 0.15, 0.55)],
	"fd_tear_gas": [Look.GAS, Color(0.86, 0.86, 0.66, 0.5)],
	"fd_nuke_gas": [Look.GAS, Color(0.35, 0.85, 0.25, 0.55)],
	"fd_relax_gas": [Look.GAS, Color(0.86, 0.6, 0.8, 0.45)],
	"fd_swamp_gas": [Look.GAS, Color(0.5, 0.55, 0.3, 0.45)],
	"fd_fog": [Look.GAS, Color(0.85, 0.87, 0.9, 0.55)],
	"fd_fungal_haze": [Look.GAS, Color(0.7, 0.62, 0.5, 0.5)],
	"fd_hallucinogenic_spores": [Look.GAS, Color(0.65, 0.45, 0.8, 0.5)],
	"fd_fungicidal_gas": [Look.GAS, Color(0.75, 0.8, 0.85, 0.45)],
	"fd_insecticidal_gas": [Look.GAS, Color(0.8, 0.85, 0.75, 0.45)],
	"fd_extinguisher": [Look.GAS, Color(0.93, 0.95, 0.97, 0.6)],
	"fd_pollen_triffid": [Look.GAS, Color(0.9, 0.8, 0.3, 0.45)],
	"fd_tindalos_gas": [Look.GAS, Color(0.3, 0.45, 0.85, 0.5)],
	"fd_nm_monster_gas_1": [Look.GAS, Color(0.5, 0.3, 0.45, 0.5)],
	"fd_nm_monster_gas_2": [Look.GAS, Color(0.3, 0.45, 0.35, 0.5)],
	"fd_bee_swarm": [Look.SWARM, Color(0.16, 0.12, 0.04, 0.95)],
}

var view_z_max := CddaCoords.Z_LIMIT
## Instances per look at most (tests lower it).
var max_per_look := MAX_PER_LOOK
var _layers := {}      # Look -> MultiMeshInstance3D
var _counts := {}      # Look -> instances drawn by the last apply
static var _shaders := {}


func _init() -> void:
	name = "Fields"


## Instances drawn after the last apply: all of them, or one look's.
func count(look := -1) -> int:
	if look >= 0:
		return _counts.get(look, 0)
	var n := 0
	for k: int in _counts:
		n += _counts[k]
	return n


func apply(snap: Snapshot, world: WorldView) -> void:
	var by_look := {}   # Look -> [[Transform3D, Color, phase], ...]
	if world.tables != null:
		for sm: Snapshot.Submap in snap.submaps.values():
			if sm.pos.z > view_z_max or sm.fields.is_empty():
				continue
			var base := CddaCoords.sm_to_ms(sm.pos)
			for j in range(0, sm.fields.size() - Snapshot.FIELD_STRIDE + 1, Snapshot.FIELD_STRIDE):
				var d: IdTables.Def = world.tables.def_at("field", sm.fields[j + 1])
				if d == null or not KINDS.has(d.id):
					continue
				var look: int = KINDS[d.id][0]
				var list: Array = by_look.get(look, [])
				if list.size() >= max_per_look:
					continue
				var t := sm.fields[j]
				var sq := base + Vector3i(t % CddaCoords.SEEX, t / CddaCoords.SEEX, 0)
				place(list, look, KINDS[d.id][1], world.coords.ms_to_world(sq), sq, clampi(sm.fields[j + 2], 1, 3),
						max_per_look)
				by_look[look] = list
	_counts.clear()
	for look: int in _layers.keys():
		if not by_look.has(look):
			(_layers[look] as Node).free()
			_layers.erase(look)
	for look: int in by_look:
		var mi: MultiMeshInstance3D = _layers.get(look)
		if mi == null:
			mi = _layer(look)
			add_child(mi)
			_layers[look] = mi
		var xs: Array = by_look[look]
		var mm := mi.multimesh
		mm.instance_count = xs.size()
		for i in xs.size():
			mm.set_instance_transform(i, xs[i][0])
			mm.set_instance_color(i, xs[i][1])
			mm.set_instance_custom_data(i, Color(xs[i][2], 0, 0, 0))
		_counts[look] = xs.size()


func shift(d: Vector3) -> void:
	for mi: MultiMeshInstance3D in _layers.values():
		mi.position += d


## Adds the quads of one field on square `sq` (corner `at`, world) to `list` as [transform, colour, phase],
## up to `cap` entries. The transform's scale is the quad's size; its origin the quad's centre.
static func place(list: Array, look: int, col: Color, at: Vector3, sq: Vector3i, intensity: int, cap: int) -> void:
	var h := absi(hash(sq))
	var n: int
	match look:
		Look.FLAME:
			n = intensity
		Look.SPARK:
			n = 1 + intensity
		Look.GAS:
			n = intensity
		_:
			n = 4 + 3 * intensity
	for k in n:
		if list.size() >= cap:
			return
		var hk := absi(hash(h + k * 7919))
		var u := 0.2 + 0.6 * float(hk % 97) / 96.0
		var v := 0.2 + 0.6 * float((hk >> 7) % 97) / 96.0
		var phase := float((hk >> 14) % 1000) / 1000.0
		var size: Vector2
		var y: float
		var c := col
		match look:
			Look.FLAME:
				size = Vector2(0.35 + 0.15 * intensity, 0.3 + 0.3 * intensity) * (0.8 + 0.4 * phase)
				y = size.y * 0.5
			Look.SPARK:
				size = Vector2.ONE * (0.08 + 0.05 * intensity) * (0.7 + 0.6 * phase)
				y = 0.2 + 1.4 * float((hk >> 4) % 89) / 88.0
			Look.GAS:
				size = Vector2.ONE * (1.0 + 0.15 * intensity) * (0.85 + 0.3 * phase)
				y = 0.45 + 0.85 * k   # a full tile fills the room's height from the floor up
				c.a = col.a * (0.3 + 0.7 * intensity / 3.0) * 0.55
			_:
				size = Vector2.ONE * 0.035
				y = 0.5 + 1.2 * float((hk >> 4) % 89) / 88.0
		list.append([Transform3D(Basis.from_scale(Vector3(size.x, size.y, 1.0)), at + Vector3(u, y, v)), c, phase])


static func _layer(look: int) -> MultiMeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := ShaderMaterial.new()
	mat.shader = shader(look)
	if look == Look.GAS or look == Look.SWARM:
		mat.render_priority = WorldLighting.UNDER_PRIORITY   # darkened by the light pass; flames and sparks glow
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = quad
	var mi := MultiMeshInstance3D.new()
	mi.name = Look.keys()[look].to_lower()
	mi.multimesh = mm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 2.0   # quads move in the shader
	return mi


## The shader of a look (made once).
static func shader(look: int) -> Shader:
	var s: Shader = _shaders.get(look)
	if s == null:
		s = Shader.new()
		s.code = _code(look)
		_shaders[look] = s
	return s


static func _code(look: int) -> String:
	var flame := look == Look.FLAME
	var glow := look == Look.SPARK   # added light; flames blend, so they stay orange against a bright sky
	var head := "shader_type spatial;\nrender_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, %s;\n" % (
			"blend_add" if glow else "blend_mix")
	var vert := """
varying float v_phase;
void vertex() {
	v_phase = INSTANCE_CUSTOM.x;
	float t = TIME + v_phase * 6.2831;
	vec3 o = MODEL_MATRIX[3].xyz;
	vec2 sz = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	%s
	vec3 right = MAIN_CAM_INV_VIEW_MATRIX[0].xyz;
	vec3 up = MAIN_CAM_INV_VIEW_MATRIX[1].xyz;
	%s
	vec3 w = o + right * VERTEX.x * sz.x + up * VERTEX.y * sz.y;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(w, 1.0);
}
""" % [
		{Look.FLAME: "sz *= vec2(1.0 + 0.08 * sin(t * 9.0), 1.0 + 0.2 * sin(t * 13.0 + 1.3)); o.y += sz.y * 0.1 * sin(t * 13.0 + 1.3);",
		Look.SPARK: "sz *= 0.5 + 0.5 * step(0.4, fract(t * 3.1)); o += vec3(sin(t * 7.0), cos(t * 5.0), sin(t * 3.0)) * 0.05;",
		Look.GAS: "o += vec3(sin(t * 0.31) * 0.15, fract(TIME * 0.05 + v_phase) * 0.25, cos(t * 0.23) * 0.15);",
		Look.SWARM: "o += vec3(sin(t * 3.7), sin(t * 2.3) * 0.5, cos(t * 3.1)) * 0.35;"}[look],
		# Flames stand upright: right stays horizontal, up is world up (unless looking straight down).
		"right = normalize(vec3(right.x, 0.0, right.z) + vec3(0.0001)); up = vec3(0.0, 1.0, 0.0);" if flame else ""]
	var frag: String
	if flame:
		frag = """
void fragment() {
	vec2 q = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y);
	float wob = 0.12 * sin(q.y * 9.0 - TIME * 11.0 + v_phase * 30.0) * q.y;
	float width = mix(0.85, 0.05, pow(q.y, 0.8));
	float a = smoothstep(width, width * 0.3, abs(q.x + wob)) * smoothstep(0.0, 0.12, q.y);
	float core = smoothstep(0.5, 0.0, length(vec2(q.x * 1.6, q.y - 0.25)));
	ALBEDO = mix(COLOR.rgb, vec3(1.0, 0.86, 0.45), core * 0.8);
	ALPHA = a * 0.92;
}
"""
	elif glow:
		frag = """
void fragment() {
	float a = smoothstep(1.0, 0.0, length(UV * 2.0 - 1.0));
	ALBEDO = COLOR.rgb * a * 2.0;
	ALPHA = a;
}
"""
	else:
		frag = """
void fragment() {
	float r = length(UV * 2.0 - 1.0);
	float a = smoothstep(1.0, 0.1, r);
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a * a;
}
"""
	return head + vert + frag
