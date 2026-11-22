class_name VrBusy
extends Label3D
## The flat screen's busy note in VR (VrRig `busy`, on the XR camera): while the game runs on by itself (a wait,
## sleep, a long craft or a gun mod being fitted) it says so low in the view, "Sleeping..." or CDDA's verb
## ("Waiting..."), else "Time passes...", so the headset never looks hung while no snapshot comes. Its text and when it
## shows are the flat BusyNote's (`source`, main.gd ticks it in VR too); this only draws it. Small, steady, no fade or
## motion beyond the note's own dots; over the world and the edges (render priority), under the menus' panel.
## Real time paused (the HUD's time line, `clock`: a hostile's auto-pause or the menu's Time row) it says that instead,
## with how to go on; a note `flash`ed (the Time row's answer) goes over both for FLASH_MS.

const DIST := 1.0            # m in front of the eyes ...
const DROP := 0.24           # ... and this far below the view's middle (about 14 degrees)
const PRIORITY := 105        # over the edges (mood 98, hurt 99, vignette 100), under the menu (110)
const MAX_CHARS := 40
const FLASH_MS := 2500
const PAUSED_HEAD := "TIME PAUSED"   # how ClockControl.text's line starts while real time is paused
const GO_ON := "menu > Time: go on"

var source: BusyNote         # the flat note: its text and visibility; null: hidden
var clock := Callable()      # -> the HUD's time line (HudData.clock, main.gd's); unset or "": none
var _flash := ""
var _flash_until := 0


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


## Shows `note` (capped) for FLASH_MS over everything else it says.
func flash(note: String, now_ms := Time.get_ticks_msec()) -> void:
	_flash = note.strip_edges().left(MAX_CHARS)
	_flash_until = now_ms + FLASH_MS


## The time line while real time is paused ("TIME PAUSED: hostile spotted", capped), else "".
func paused_line() -> String:
	var c: Variant = clock.call() if clock.is_valid() else ""
	return (c as String).left(MAX_CHARS) if c is String and (c as String).begins_with(PAUSED_HEAD) else ""


## Shows a flashed note, else real time paused (with how to go on), else the source's note (capped); hidden when
## none says anything.
func step(now_ms := Time.get_ticks_msec()) -> void:
	var t := ""
	if not _flash.is_empty() and now_ms < _flash_until:
		t = _flash
	else:
		_flash = ""
		var p := paused_line()
		if not p.is_empty():
			t = p + "\n" + GO_ON
		elif source != null and is_instance_valid(source) and source.visible and not source.text.is_empty():
			t = source.text.left(MAX_CHARS)
	visible = not t.is_empty()
	if visible and t != text:
		text = t
