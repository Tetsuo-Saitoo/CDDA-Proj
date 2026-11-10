extends RefCounted
## C9 views next to first person: ViewCamera's shoulder and top poses (boom shortened by walls, zoom limits),
## the start view from --view= / --camera= / the saved setting, the setting's file round trip, and reach
## counted from the eyes when the camera is away from them. Run by run_tests.gd.

const Main := preload("res://scripts/main.gd")

var _check: Callable


func run(check: Callable) -> void:
	_check = check
	print("views")
	_test_poses()
	_test_follow()
	_test_start_view()
	_test_setting()
	_test_reach_from_eyes()


func _near(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) < 1e-3


func _test_poses() -> void:
	var eye := Vector3(10, 1.6, -4)
	var sh := ViewCamera.pose("shoulder", eye, 0.0, 0.0)
	_check.call(_near(sh.origin, eye + Vector3(ViewCamera.SHOULDER_RIGHT, ViewCamera.SHOULDER_UP, ViewCamera.SHOULDER_BACK))
			and _near(-sh.basis.z, Vector3.FORWARD), "views: shoulder sits behind, right and above, looking where the eyes look")
	var turned := ViewCamera.pose("shoulder", eye, PI / 2, 0.0)   # looking west (-x)
	_check.call(turned.origin.x > eye.x + 2.0 and _near(-turned.basis.z, Vector3.LEFT), "views: shoulder turns with the eyes")
	var half := ViewCamera.pose("shoulder", eye, 0.0, 0.0, ViewCamera.TOP_DIST, 0.5)
	_check.call(_near(half.origin - eye, (sh.origin - eye) * 0.5), "views: a shortened boom pulls in along the same line")
	var top := ViewCamera.pose("top", eye, 0.0, 0.7)
	var at := eye - Vector3(0, FirstPersonCamera.EYE_H * 0.5, 0)
	var to_at := (at - top.origin).normalized()
	_check.call(top.origin.y > eye.y + 8.0 and top.origin.z > eye.z and _near(-top.basis.z, to_at)
			and is_equal_approx(top.origin.distance_to(at), ViewCamera.TOP_DIST),
			"views: top looks down at the player from high and behind, whatever the eyes' pitch")
	var far := ViewCamera.pose("top", eye, 0.0, 0.0, 1000.0)
	_check.call(is_equal_approx(far.origin.distance_to(at), ViewCamera.TOP_MAX), "views: top distance clamped")
	_check.call(ViewCamera.boom_for(INF) == 1.0 and ViewCamera.boom_for(NAN) == 1.0 and ViewCamera.boom_for(100.0) == 1.0
			and ViewCamera.boom_for(0.0) > 0.0 and ViewCamera.boom_for(1.0) < 0.5, "views: boom from the free distance")


func _test_follow() -> void:
	var w := WorldView.new()
	var fp := FirstPersonCamera.new(w)
	fp.position = Vector3(0, 1.6, 0)
	fp.set_look(0.0, -0.2)
	var vc := ViewCamera.new(fp)
	vc.follow()
	var full := vc.transform.origin.distance_to(fp.position)
	var asked: Array = []
	vc.blocked = func(a: Vector3, b: Vector3) -> float:
		asked.append([a, b])
		return 1.0
	vc.follow()
	var short := vc.transform.origin.distance_to(fp.position)
	_check.call(full > 2.0 and short < 1.0 and asked.size() == 1 and _near(asked[0][0], fp.position),
			"views: a wall 1 m behind pulls the shoulder camera in (%.2f -> %.2f m)" % [full, short])
	vc.blocked = func(_a: Vector3, _b: Vector3) -> Variant: return "junk"
	vc.follow()
	_check.call(is_equal_approx(vc.transform.origin.distance_to(fp.position), full), "views: a junk answer leaves the full boom")
	vc.mode = "top"
	vc.zoom(-100)
	var near_d := vc.top_dist
	vc.zoom(100)
	_check.call(near_d == ViewCamera.TOP_MIN and vc.top_dist == ViewCamera.TOP_MAX, "views: zoom stays within limits")
	vc.free()
	fp.free()
	w.free()


func _test_start_view() -> void:
	_check.call(Main.start_view({"view": "shoulder"}, "top") == "shoulder" and Main.start_view({}, "top") == "top"
			and Main.start_view({"camera": "1,2,3,0,0"}, "top") == "outside" and Main.start_view({}, "sideways") == "first"
			and Main.start_view({}, "") == "first", "views: --view= first, then --camera= (outside), then the saved view")
	_check.call(Main.VIEW_MODES == ["first", "shoulder", "top", "outside"], "views: V cycles first, shoulder, top, outside")


func _test_setting() -> void:
	var path: String = preload("res://tests/test_dir.gd").path("hud_view.cfg")
	var s := HudSettings.new()
	s.view = "top"
	s.save_file(path)
	var r := HudSettings.new()
	r.load_file(path)
	_check.call(r.view == "top", "views: the view is saved and read back")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[view]\nmode=\"../../etc\"\n")
	f.close()
	var j := HudSettings.new()
	j.view = "top"
	j.load_file(path)
	var f2 := FileAccess.open(path, FileAccess.WRITE)
	f2.store_string("[view]\nmode=3\n")
	f2.close()
	var k := HudSettings.new()
	k.load_file(path)
	_check.call(j.view == "first" and k.view == "first", "views: an unknown or non-text view in the file reads as first")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_reach_from_eyes() -> void:
	var o := Vector3(0, 5, 5)
	var d := Vector3(0, -1, -1).normalized()
	var e := Vector3(0, 1.6, 1.6)
	var moved := GrabController.from_eyes(o, d, e)
	_check.call(_near(moved, e) and _near(GrabController.from_eyes(o, d, null), o)
			and _near(GrabController.from_eyes(o, d, Vector3(0, 9, 9)), o)
			and _near(GrabController.from_eyes(o, d, Vector3(NAN, 0, 0)), o),
			"views: reach starts where the ray passes the eyes (never behind the camera; none: the camera)")
