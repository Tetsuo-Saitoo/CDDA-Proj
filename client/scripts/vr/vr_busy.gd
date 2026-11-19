class_name VrBusy
extends Label3D
## The flat screen's busy note in VR (VrRig `busy`, on the XR camera): while the game runs on by itself (a wait,
## sleep, a long craft or a gun mod being fitted) it says so low in the view, "Sleeping..." or CDDA's verb
## ("Waiting..."), else "Time passes...", so the headset never looks hung while no snapshot comes. Its text and when it
## shows are the flat BusyNote's (`source`, main.gd ticks it in VR too); this only draws it. Small, steady, no fade or
## motion beyond the note's own dots; over the world and the edges (render priority), under the menus' panel.

const DIST := 1.0            # m in front of the eyes ...
const DROP := 0.24           # ... and this far below the view's middle (about 14 degrees)
const PRIORITY := 105        # over the edges (mood 98, hurt 99, vignette 100), under the menu (110)
const MAX_CHARS := 40

var source: BusyNote         # the flat note: its text and visibility; null: hidden


func _init() -> void:
	name = "BusyNote"
	position = Vector3(0, -DROP, -DIST)
	pixel_size = 0.0012
	font_size = 32
	outline_size = 10
	modulate = Color(0.92, 0.94, 1.0)
	no_depth_test = true
	render_priority = PRIORITY
	outline_render_priority = PRIORITY - 1
	fixed_size = false
	shaded = false
	double_sided = false
	visible = false


func _process(_delta: float) -> void:
	step()


## Shows the source's note (capped), hidden while it shows none or there is no source.
func step() -> void:
	var on := source != null and is_instance_valid(source) and source.visible and not source.text.is_empty()
	visible = on
	if on:
		var t := source.text.left(MAX_CHARS)
		if t != text:
			text = t
