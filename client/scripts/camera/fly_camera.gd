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
		if mb.is_action(&"look"):
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mb.pressed else Input.MOUSE_MODE_VISIBLE
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed = minf(speed * 1.25, 200.0)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed = maxf(speed / 1.25, 1.0)
	elif event is InputEventKey and event.is_action(&"look"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.is_pressed() else Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * sensitivity
		_pitch = clampf(_pitch - mm.relative.y * sensitivity, -1.55, 1.55)
		rotation = Vector3(_pitch, _yaw, 0)


func _process(delta: float) -> void:
	var v := Vector3.ZERO
	var mv := Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward")
	v += basis.x * mv.x - basis.z * mv.y
	v += Vector3.UP * (Input.get_action_strength(&"fly_up") - Input.get_action_strength(&"fly_down"))
	if v != Vector3.ZERO:
		var s := speed * (4.0 if Input.is_action_pressed(&"move_fast") else 1.0)
		position += v.normalized() * s * delta
