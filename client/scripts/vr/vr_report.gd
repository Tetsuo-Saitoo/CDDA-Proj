class_name VrReport
extends RefCounted
## In-headset bug report (the VR menu's row "Report a bug", VrRig.report_bug): what the tester was doing, written to
## one text file with a picture of the view next to it, under user://bug_reports/ for the tester to send. Numbers,
## ids and settings only: no save or character name, no game messages. The newest MAX_KEPT reports are kept.

const DIR := "user://bug_reports"
const MAX_KEPT := 20
const LOG_LINES := 30           # lines of vr_perf.log at the end of a report
const MAX_TAIL_BYTES := 16384   # read from the end of the log, at most


## The report's text for rig `r` as it is now.
static func text(r: VrRig) -> String:
	var lines := PackedStringArray()
	lines.append("CDDA-3D VR bug report, %s" % Time.get_datetime_string_from_system())
	var v := str(ProjectSettings.get_setting("application/config/version", ""))
	lines.append("version: %s" % (v if not v.is_empty() else "?"))
	lines.append("runtime: " + VrPerf.runtime_text(XRServer.primary_interface))
	lines.append("controllers: %s (layout %s)" % [VrPerf.controllers_text(), r.current_layout()])
	lines.append("settings: " + VrSettings.changed_text(r.settings))
	var snap := r.world.snapshot if r.world != null else null
	lines.append("game: " + ("turn %d, square %s, level %d" % [snap.turn, snap.player_pos, r.z] if snap != null else "none"))
	lines.append("head: " + _pose(r.camera))
	for i in 2:
		lines.append("%s hand: %s, tracked %s, holds %s" % [["left", "right"][i], _pose(r.left if i == 0 else r.right),
				r.tracked(i), _held(r, i)])
	lines.append("open: menu %s, panel %s, pack %s" % [r.menu_open(), r.panel != null and r.panel.shown,
			r.pack != null and r.pack.hand >= 0])
	lines.append("--- the end of vr_perf.log")
	lines.append_array(tail(VrPerf.LOG_PATH, LOG_LINES))
	return "\n".join(lines) + "\n"


## Writes `body`, and `shot` as a PNG beside it when there is one, under `dir`; then only the newest MAX_KEPT
## reports stay. The text file's path, "" when it couldn't be written.
static func save(body: String, shot: Image, dir := DIR) -> String:
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		return ""
	var stamp := Time.get_datetime_string_from_system().replace("-", "").replace(":", "").replace("T", "-")
	var base := "%s/report-%s" % [dir, stamp]
	for k in range(2, 100):   # two in one second
		if not FileAccess.file_exists(base + ".txt"):
			break
		base = "%s/report-%s-%02d" % [dir, stamp, k]
	var f := FileAccess.open(base + ".txt", FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(body)
	f.close()
	if shot != null and not shot.is_empty():
		shot.save_png(base + ".png")
	prune(dir)
	return base + ".txt"


## Removes all but the newest MAX_KEPT reports (text and picture) in `dir`.
static func prune(dir: String) -> void:
	var names: Array[String] = []
	for n in DirAccess.get_files_at(dir):
		if n.begins_with("report-") and n.ends_with(".txt"):
			names.append(n.get_basename())
	names.sort()
	for k in maxi(names.size() - MAX_KEPT, 0):
		for ext in [".txt", ".png"]:
			var p := "%s/%s%s" % [dir, names[k], ext]
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


## The last `n` lines of the file at `path` (at most MAX_TAIL_BYTES from its end), cleaned.
static func tail(path: String, n: int) -> PackedStringArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedStringArray(["(none)"])
	var size := f.get_length()
	f.seek(maxi(size - MAX_TAIL_BYTES, 0))
	var lines := f.get_buffer(mini(size, MAX_TAIL_BYTES)).get_string_from_utf8().split("\n", false)
	var out := PackedStringArray()
	for l in lines.slice(maxi(lines.size() - n, 0)):
		out.append(Snapshot.plain_text(l, 240))
	return out


## Where node `n` is in the rig's space, to the centimetre, and its compass heading (0 north = -Z, 90 east); "-" when
## it isn't there or has no finite pose.
static func _pose(n: Node3D) -> String:
	if n == null or not n.transform.is_finite():
		return "-"
	var p := n.position.snapped(Vector3.ONE * 0.01)
	var f := -n.transform.basis.z
	return "at (%.2f, %.2f, %.2f) heading %d" % [p.x, p.y, p.z, wrapi(roundi(rad_to_deg(atan2(f.x, -f.z))), 0, 360)]


## What hand i holds: the kind and the item's id ("nothing", "-" without hands).
static func _held(r: VrRig, i: int) -> String:
	if r.hands == null:
		return "-"
	var h := r.hands.holding(VrRig.HAND_IDS[i])
	if h.is_empty():
		return "nothing"
	var id := ""
	var it: Variant = h.get("item")
	var t := r.world.tables if r.world != null else null
	if it is ItemRef and t != null and (it as ItemRef).type >= 0 and (it as ItemRef).type < t.itype.size():
		id = " " + Snapshot.plain_text(t.itype[(it as ItemRef).type].id, 64)
	return Snapshot.plain_text(str(h.get("kind", "?")), 16) + id
