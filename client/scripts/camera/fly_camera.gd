class_name FlyCamera
extends Camera3D
## Free-fly debug camera: hold the right mouse button to look, WASD to move, E/Space up, Q/Ctrl down,
## Shift for 4x speed, mouse wheel changes speed.

var speed := 12.0
var sensitivity := 0.003
var _yaw := 0.0
var _pitch := -0.6


func _ready() -> void:
	near = 0.05
	far = 600.0
	rotation = Vector3(_pitch, _yaw, 0)


func look_from(from: Vector3, target: Vector3) -> void:
	position = from
	look_at(target)
	_pitch = rotation.x
	_yaw = rotation.y
	rotation = Vector3(_pitch, _yaw, 0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mb.pressed else Input.MOUSE_MODE_VISIBLE
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed = minf(speed * 1.25, 200.0)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed = maxf(speed / 1.25, 1.0)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * sensitivity
		_pitch = clampf(_pitch - mm.relative.y * sensitivity, -1.55, 1.55)
		rotation = Vector3(_pitch, _yaw, 0)


func _process(delta: float) -> void:
	var v := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		v -= basis.z
	if Input.is_physical_key_pressed(KEY_S):
		v += basis.z
	if Input.is_physical_key_pressed(KEY_A):
		v -= basis.x
	if Input.is_physical_key_pressed(KEY_D):
		v += basis.x
	if Input.is_physical_key_pressed(KEY_E) or Input.is_physical_key_pressed(KEY_SPACE):
		v += Vector3.UP
	if Input.is_physical_key_pressed(KEY_Q) or Input.is_physical_key_pressed(KEY_CTRL):
		v -= Vector3.UP
	if v != Vector3.ZERO:
		var s := speed * (4.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
		position += v.normalized() * s * delta
