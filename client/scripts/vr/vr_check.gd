class_name VrCheck
extends Node
## Automated checks inside a real VR session (`-- --vr --vr-check=<names>`, e.g. under SteamVR's null headset,
## TASKS "VR without a headset"): once the world is up and the session has drawn frames, each named scenario runs
## on the live rig and prints `vr check ok: ...` / `vr check FAIL: ...` lines, then a summary line
## `vr check: N ok, M failed`, and the game quits (main.gd `_quit`). The lines also go to user://vr_check.log.
## There are no controllers under the null headset: the rig counts its hands as tracked and the scenario places them.
## Scenarios: "report" (the bug report row saves a text and a picture of the view).

const LOG_PATH := "user://vr_check.log"
const START_FRAMES := 30          # frames drawn before the first scenario
const MAX_WAIT_S := 120.0         # for the world to come up

var rig: VrRig
var quit := Callable()            # main.gd's _quit
var oks := 0
var fails := 0
var _log: FileAccess


func run(names: String) -> void:
	_log = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	var t := 0.0
	while rig.world.snapshot == null and t < MAX_WAIT_S:
		await get_tree().process_frame
		t += get_process_delta_time()
	for k in START_FRAMES:
		await get_tree().process_frame
	rig.assume_tracked = true
	for n in names.split(",", false):
		match n.strip_edges():
			"report":
				await _report()
			var other:
				_check(false, "unknown scenario '%s'" % Snapshot.plain_text(other, 40))
	_line("vr check: %d ok, %d failed" % [oks, fails])
	if _log != null:
		_log.close()
	if quit.is_valid():
		quit.call()


func _check(ok: bool, what: String) -> void:
	if ok:
		oks += 1
	else:
		fails += 1
	_line(("vr check ok: " if ok else "vr check FAIL: ") + what)


func _line(s: String) -> void:
	print(s)
	if _log != null:
		_log.store_line(s)


## The menu's "Report a bug": a new report with a picture that isn't one flat colour.
func _report() -> void:
	var before := _reports()
	rig.report_bug()
	var path := ""
	for k in 240:
		await get_tree().process_frame
		for n in _reports():
			if n.ends_with(".png") and not before.has(n):
				path = VrReport.DIR + "/" + n
		if not path.is_empty():
			break
	var img: Image = Image.load_from_file(path) if not path.is_empty() else null
	var varied := false
	if img != null and not img.is_empty():
		var c0 := img.get_pixel(0, 0)
		for k in 64:
			var p := img.get_pixel(int(img.get_width() * ((k % 8) + 0.5) / 8.0), int(img.get_height() * (floori(k / 8.0) + 0.5) / 8.0))
			if not p.is_equal_approx(c0):
				varied = true
				break
	_check(img != null and varied, "report: a bug report with a picture of the view (%s)" % path)


func _reports() -> PackedStringArray:
	return DirAccess.get_files_at(VrReport.DIR) if DirAccess.dir_exists_absolute(VrReport.DIR) else PackedStringArray()
