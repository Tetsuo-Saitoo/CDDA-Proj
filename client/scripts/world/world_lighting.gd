class_name WorldLighting
extends Node3D
## Block C6: shows CDDA's light. A full-screen pass (shaders/world_light.gdshader) multiplies what is drawn by
## the light of the tile each pixel shows (LightMap: light, vis, night tint, lamp warmth) and the sky by the
## natural light; OmniLights stand at the nearest light sources, the nearest `shadow_lamps` of them casting
## shadows so walls keep a lamp's light in its room. WorldView owns it and gives it a LightMap per
## snapshot (built on its worker); the scene's own lights stay bright, so this pass alone does the darkening.
##
## The pass is drawn first among transparent things (PASS_PRIORITY): fire, explosions, glyphs, markers and VR
## panels drawn after it stay bright. World surfaces that are transparent (glass, blood, see-through parts of
## models) use UNDER_PRIORITY, so they are drawn before it and darkened with what is behind them.

const PASS_PRIORITY := -100
const UNDER_PRIORITY := -110
## Outside view: nothing darker than this, so the map stays readable at night.
const OUTSIDE_MIN := 0.25
const LAMP := Color(1.0, 0.8, 0.55)
const FIRE := Color(1.0, 0.58, 0.28)
const SHADER := preload("res://shaders/world_light.gdshader")
const SHADOW_LAMPS := 4   # default shadow_lamps: shadows cost a render of the casters near each lamp that changed
const VR_SHADOW_LAMPS := 0   # default vr_shadow_lamps: off in VR until their cost at 90 fps is measured
const GAZE_BLOBS := 3        # the shader's gaze_blobs

## Off: no darkening and no lamps (--no-light).
var enabled := true:
	set(v):
		enabled = v
		_update_visible()
## How many of the lamps (the nearest to the player first) cast shadows, 0..LightMap.MAX_SOURCES; in VR (the
## viewport uses XR) at most vr_shadow_lamps of them.
var shadow_lamps := SHADOW_LAMPS:
	set(v):
		shadow_lamps = clampi(v, 0, LightMap.MAX_SOURCES)
		_place_shadows()
var vr_shadow_lamps := VR_SHADOW_LAMPS:
	set(v):
		vr_shadow_lamps = clampi(v, 0, LightMap.MAX_SOURCES)
		_place_shadows()
## Lowest multiplier for world pixels (not the sky).
var min_brightness := 0.0:
	set(v):
		min_brightness = clampf(v, 0.0, 1.0)
		_mat.set_shader_parameter("min_brightness", min_brightness)
var fog := Vector3(0.0, 1.0, 0.0)   # begin (m), end (m), amount: see set_fog
## Lightning: for a moment nothing, the sky included, is darker than this (WeatherView).
var flash := 0.0:
	set(v):
		flash = clampf(v, 0.0, 1.0)
		_mat.set_shader_parameter("flash", flash)
## The scene's depth fog, so fogged distance takes the sky's light instead of its tiles' (WeatherView).
## `amount` 0: no fog.
func set_fog(begin_m: float, end_m: float, amount: float) -> void:
	var begin := maxf(begin_m, 0.0)
	fog = Vector3(begin, maxf(end_m, begin + 0.01), clampf(amount, 0.0, 1.0))
	_mat.set_shader_parameter("fog_begin", fog.x)
	_mat.set_shader_parameter("fog_end", fog.y)
	_mat.set_shader_parameter("fog_amount", fog.z)


## Natural light the shown LUT was built for (-1: none yet); WorldView rebuilds the LUT only when it changes.
var lut_ambient := -1
var ambient := -1          # natural light of the last applied map
var levels := 0
var sources_shown := 0     # OmniLights in use
var map: LightMap          # the last applied (GazeEffects looks up what the eyes see)
var _mat := ShaderMaterial.new()
var _quad := MeshInstance3D.new()
var _atlas: ImageTexture
var _lut: ImageTexture
var _lights: Array[OmniLight3D] = []


func _init() -> void:
	name = "Lighting"
	_mat.shader = SHADER
	_mat.render_priority = PASS_PRIORITY
	var q := QuadMesh.new()
	q.size = Vector2(2, 2)
	_quad.name = "pass"
	_quad.mesh = q
	_quad.material_override = _mat
	_quad.extra_cull_margin = 16384.0
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_quad.ignore_occlusion_culling = true
	_quad.visible = false
	add_child(_quad)
	for i in LightMap.MAX_SOURCES:
		var l := OmniLight3D.new()
		l.name = "lamp_%d" % i
		l.shadow_enabled = i < shadow_lamps   # sources come nearest first (LightMap); _place_shadows
		l.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID   # two renders, not six
		l.light_specular = 0.25
		l.omni_attenuation = 1.5
		l.visible = false
		add_child(l)
		_lights.append(l)


## Shows a map built for the snapshot `coords` was just rebased on. Main thread.
func apply(m: LightMap, coords: CddaCoords) -> void:
	map = m
	if m.lut != null:
		_lut = _upload(_lut, m.lut, "lut")
		lut_ambient = m.ambient
	_atlas = _upload(_atlas, m.image, "atlas")
	ambient = m.ambient
	levels = m.levels
	var o := coords.ms_to_world(m.origin_ms)
	if is_inside_tree():
		o = global_transform * o
	_mat.set_shader_parameter("origin", o)
	_mat.set_shader_parameter("z_lo", m.z_lo)
	_mat.set_shader_parameter("levels", m.levels)
	_mat.set_shader_parameter("sky_color", _vec(m.sky))
	_mat.set_shader_parameter("outside_color", _vec(m.outside))
	_place_shadows()
	sources_shown = 0
	for i in _lights.size():
		var l := _lights[i]
		l.set_meta("used", i < m.sources.size())
		if i >= m.sources.size():
			continue
		var s := m.sources[i]
		var height := 0.4 if s.kind == Snapshot.LIGHT_FIRE else (1.0 if s.kind == Snapshot.LIGHT_ITEM else 1.5)
		l.position = coords.ms_center_to_world(s.square) + Vector3(0, height, 0)
		l.light_color = FIRE if s.kind == Snapshot.LIGHT_FIRE else LAMP
		l.omni_range = LightMap.light_range(s.luminance)
		l.light_energy = LightMap.light_energy(s.luminance)
		sources_shown += 1
	_update_visible()


## The eye-tracking effects (GazeEffects): lit pixels `boost` brighter, all but a small cone about `glare_dir`
## `glare` darker, and up to GAZE_BLOBS soft shadows, each [direction (unit, world), cos of its radius, strength
## 0..1]. All 0 / []: the pass as without them. Values are bounded here too.
func set_gaze(boost: float, glare: float, glare_dir: Vector3, blobs: Array) -> void:
	var dirs := PackedVector4Array()
	var cosines := PackedFloat32Array()
	for i in GAZE_BLOBS:
		var e: Variant = blobs[i] if i < blobs.size() else null
		var ok: bool = e is Array and (e as Array).size() == 3 and e[0] is Vector3 and (e[0] as Vector3).is_finite() \
				and (e[0] as Vector3).length() > 0.5 and e[1] is float and is_finite(e[1]) and e[2] is float and is_finite(e[2])
		var d: Vector3 = (e[0] as Vector3).normalized() if ok else Vector3.FORWARD
		dirs.append(Vector4(d.x, d.y, d.z, clampf(e[2], 0.0, 1.0) if ok else 0.0))
		cosines.append(clampf(e[1], 0.0, 0.999) if ok else 0.0)
	var gd := glare_dir.normalized() if glare_dir.is_finite() and glare_dir.length() > 0.5 else Vector3.FORWARD
	_mat.set_shader_parameter("gaze_boost", clampf(boost, 0.0, 1.0) if is_finite(boost) else 0.0)
	_mat.set_shader_parameter("gaze_glare", clampf(glare, 0.0, 0.9) if is_finite(glare) else 0.0)
	_mat.set_shader_parameter("gaze_glare_dir", gd)
	_mat.set_shader_parameter("gaze_blobs", dirs)
	_mat.set_shader_parameter("gaze_blob_cos", cosines)


## The eye-tracking values the pass draws now (tests): {boost, glare, blobs: PackedVector4Array}.
func gaze_now() -> Dictionary:
	return {"boost": _mat.get_shader_parameter("gaze_boost"), "glare": _mat.get_shader_parameter("gaze_glare"),
			"blobs": _mat.get_shader_parameter("gaze_blobs")}


## Lamps with shadows for these settings: shadow_lamps, at most vr_shadow_lamps in VR.
static func shadows_for(lamps: int, vr_lamps: int, xr: bool) -> int:
	return mini(lamps, vr_lamps) if xr else lamps


func _place_shadows() -> void:
	var xr := is_inside_tree() and get_viewport().use_xr
	var n := shadows_for(shadow_lamps, vr_shadow_lamps, xr)
	for i in _lights.size():
		_lights[i].shadow_enabled = i < n


## The OmniLights in use (shown or not), for tests.
func lamps() -> Array[OmniLight3D]:
	return _lights.filter(func(l: OmniLight3D) -> bool: return l.get_meta("used", false))


func pass_visible() -> bool:
	return _quad.visible


func _update_visible() -> void:
	_quad.visible = enabled and _atlas != null and _lut != null
	for l in _lights:
		l.visible = enabled and l.get_meta("used", false)


func _upload(tex: ImageTexture, img: Image, param: String) -> ImageTexture:
	if tex != null and tex.get_size() == Vector2(img.get_size()) and tex.get_format() == img.get_format():
		tex.update(img)
		return tex
	tex = ImageTexture.create_from_image(img)
	_mat.set_shader_parameter(param, tex)
	return tex


static func _vec(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)
