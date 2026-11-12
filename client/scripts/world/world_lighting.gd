class_name WorldLighting
extends Node3D
## Block C6: shows CDDA's light. A full-screen pass (shaders/world_light.gdshader) multiplies what is drawn by
## the light of the tile each pixel shows (LightMap: light, vis, night tint, lamp warmth) and the sky by the
## natural light; OmniLights stand at the nearest light sources. WorldView owns it and gives it a LightMap per
## snapshot (built on its worker); the scene's own lights stay bright, so this pass alone does the darkening.
##
## The pass is drawn first among transparent things (PASS_PRIORITY): fire, explosions, glyphs, markers and VR
## panels drawn after it stay bright. World surfaces that are transparent (glass, blood) use UNDER_PRIORITY,
## so they are drawn before it and darkened with what is behind them.

const PASS_PRIORITY := -100
const UNDER_PRIORITY := -110
## Outside view: nothing darker than this, so the map stays readable at night.
const OUTSIDE_MIN := 0.25
const LAMP := Color(1.0, 0.8, 0.55)
const FIRE := Color(1.0, 0.58, 0.28)
const SHADER := preload("res://shaders/world_light.gdshader")

## Off: no darkening and no lamps (--no-light).
var enabled := true:
	set(v):
		enabled = v
		_update_visible()
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
		l.shadow_enabled = false
		l.light_specular = 0.25
		l.omni_attenuation = 1.5
		l.visible = false
		add_child(l)
		_lights.append(l)


## Shows a map built for the snapshot `coords` was just rebased on. Main thread.
func apply(map: LightMap, coords: CddaCoords) -> void:
	if map.lut != null:
		_lut = _upload(_lut, map.lut, "lut")
		lut_ambient = map.ambient
	_atlas = _upload(_atlas, map.image, "atlas")
	ambient = map.ambient
	levels = map.levels
	var o := coords.ms_to_world(map.origin_ms)
	if is_inside_tree():
		o = global_transform * o
	_mat.set_shader_parameter("origin", o)
	_mat.set_shader_parameter("z_lo", map.z_lo)
	_mat.set_shader_parameter("levels", map.levels)
	_mat.set_shader_parameter("sky_color", _vec(map.sky))
	_mat.set_shader_parameter("outside_color", _vec(map.outside))
	sources_shown = 0
	for i in _lights.size():
		var l := _lights[i]
		l.set_meta("used", i < map.sources.size())
		if i >= map.sources.size():
			continue
		var s := map.sources[i]
		var height := 0.4 if s.kind == Snapshot.LIGHT_FIRE else (1.0 if s.kind == Snapshot.LIGHT_ITEM else 1.5)
		l.position = coords.ms_center_to_world(s.square) + Vector3(0, height, 0)
		l.light_color = FIRE if s.kind == Snapshot.LIGHT_FIRE else LAMP
		l.omni_range = LightMap.light_range(s.luminance)
		l.light_energy = LightMap.light_energy(s.luminance)
		sources_shown += 1
	_update_visible()


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
