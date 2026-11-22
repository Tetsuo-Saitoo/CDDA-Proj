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
	_test_chase()
	_test_top()
	_test_recentre()
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


## Driving (lead-world, 2026-11-21): the chase camera sits behind and above the vehicle looking at it, eases after a
## turn (never at once, shortest way round), pulls in and rises when something is in the way (its boom starts above
## the roof, so never at the vehicle it follows), follows the eyes without a vehicle; V while driving cycles first
## person, chase and top-down.
func _test_chase() -> void:
	var mid := Vector3(20, 0, 10)
	var east := ViewCamera.chase_pose(mid, 0.0)
	var look := mid + Vector3.UP * ViewCamera.CHASE_LOOK_UP
	_check.call(east.origin.x < mid.x - 5.0 and absf(east.origin.z - mid.z) < 1e-3 and east.origin.y > mid.y + 3.0
			and (-east.basis.z).is_equal_approx((look - east.origin).normalized()),
			"views: chase sits behind and above the vehicle, looking at it")
	var a := ViewCamera.chase_ease(0.0, PI / 2, 0.1)
	var b := 0.0
	for i in 50:   # 5 s at 10 frames a second
		b = ViewCamera.chase_ease(b, PI / 2, 0.1)
	var big := ViewCamera.chase_ease(0.0, PI / 2, 30.0)   # one long frame: at most a second's worth
	var wrap := ViewCamera.chase_ease(3.0, -3.0, 0.1)
	_check.call(a > 0.0 and a < PI / 4 and absf(b - PI / 2) < 0.01 and big < PI / 2 - 0.01 and ViewCamera.chase_ease(NAN, 1.0, 0.1) == 1.0
			and (wrap > 3.0 or wrap < -3.0) and ViewCamera.chase_ease(0.0, 1.0, NAN) == 1.0,
			"views: chase turns after the vehicle with a lag (%.2f after 0.1 s, %.2f after 5), the short way round" % [a, b])
	var w := WorldView.new()
	var fp := FirstPersonCamera.new(w)
	fp.position = Vector3(0, 1.6, 0)
	var vc := ViewCamera.new(fp)
	vc.mode = "chase"
	var car_xf := [Transform3D(Basis(Vector3.UP, -PI / 2), mid)]   # x ahead along +z: heading +90 degrees
	vc.car = func() -> Variant: return car_xf[0]
	vc.follow()
	var at_once := absf(vc.chase_heading - PI / 2) < 1e-4 and vc.transform.origin.z < mid.z - 5.0
	car_xf[0] = Transform3D(Basis(), mid)   # turned to heading 0 (east)
	vc.follow(1.0 / 60.0)
	var eased := vc.chase_heading < PI / 2 and vc.chase_heading > PI / 4
	var asked: Array = []
	vc.blocked = func(p: Vector3, q: Vector3) -> float:
		asked.append([p, q])
		return 1.0
	vc.follow(0.0)
	var pulled := vc.transform.origin.distance_to(mid) < east.origin.distance_to(mid) \
			and vc.transform.origin.y > mid.y + ViewCamera.CHASE_PIVOT_UP and asked.size() == 1 \
			and (asked[0][0] as Vector3).y > VehicleView.TOP + VehicleView.ROOF_T
	vc.blocked = func(_p: Vector3, _q: Vector3) -> Variant: return "junk"
	vc.follow(0.0)
	var junk := vc.transform.origin.is_equal_approx(east.origin)
	vc.car = func() -> Variant: return null
	vc.follow(0.0)
	var eyes := vc.transform.origin.distance_to(fp.position) > 5.0 and vc.transform.origin.distance_to(fp.position) < 10.0
	_check.call(at_once and eased and pulled and junk and eyes,
			"views: chase starts behind the vehicle, eases after its turn, pulls in and rises at a wall (boom from above the roof), follows the eyes without one")
	_check.call(Main.DRIVE_VIEWS == ["first", "chase", "top"] and Main.next_drive_view("first") == "chase"
			and Main.next_drive_view("chase") == "top" and Main.next_drive_view("top") == "first"
			and Main.next_drive_view("outside") == "first" and not "chase" in Main.VIEW_MODES
			and ViewCamera.ray_start("chase", Vector3(0, 5, 5), Vector3(0, 0, -1), Vector3(0, 5, 0)).is_equal_approx(Vector3(0, 5, 0)),
			"views: V while driving cycles first person, chase, top-down; walking V never picks chase")
	vc.free()
	fp.free()
	w.free()


## C5: the top view centres on the player (driving: the vehicle), turns smoothly with the facing (driving: the
## heading) or keeps north up.
func _test_top() -> void:
	var w := WorldView.new()
	var fp := FirstPersonCamera.new(w)
	fp.position = Vector3(3, 1.6, 4)
	fp.set_look(1.0, 0.0)
	var vc := ViewCamera.new(fp)
	vc.mode = "top"
	vc.follow()
	var on_foot := absf(vc.top_yaw - 1.0) < 1e-6 and vc.transform.is_equal_approx(ViewCamera.pose("top", fp.position, 1.0, 0.0))
	fp.set_look(-1.0, 0.0)
	vc.follow(0.1)
	var smooth := vc.top_yaw < 1.0 and vc.top_yaw > 0.0
	for i in 60:
		vc.follow(0.1)
	var caught := absf(vc.top_yaw + 1.0) < 0.01
	vc.top_up = "north"
	vc.follow(0.1)
	var north_turning := vc.top_yaw > -1.0 and vc.top_yaw < 0.0
	for i in 60:
		vc.follow(0.1)
	var north := absf(vc.top_yaw) < 0.01 and (-vc.transform.basis.z).z < -0.1 and absf((-vc.transform.basis.z).x) < 0.01
	vc.top_up = "heading"
	var mid := Vector3(20, 0, 10)
	vc.car = func() -> Variant: return Transform3D(Basis(Vector3.UP, -PI / 2), mid)   # x ahead along +z (south)
	vc.follow(0.0)
	var walking_ignores_car := absf(vc.top_yaw + 1.0) < 1e-6
	vc.driving = true
	vc.top_yaw = NAN
	vc.follow(0.1)
	var at := mid + Vector3.UP * (ViewCamera.TOP_CAR_UP + FirstPersonCamera.EYE_H * 0.5)
	var on_car := vc.transform.is_equal_approx(ViewCamera.pose("top", at, vc.top_yaw, 0.0, vc.top_dist)) \
			and ViewCamera.facing(vc.top_yaw).is_equal_approx(Vector3(0, 0, 1))
	vc.car = func() -> Variant: return "junk"
	vc.follow(0.0)
	var junk := vc.transform.origin.is_finite() and absf(vc.top_yaw - fp.yaw) < 1e-6
	_check.call(on_foot and smooth and caught and north_turning and north and walking_ignores_car and on_car and junk
			and is_nan(ViewCamera.heading_yaw(Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3.ZERO).rotated(Vector3.FORWARD, PI / 2))),
			"views: top centres on the player, turns smoothly after the facing or keeps north up; driving it centres on the vehicle and turns with its heading")
	vc.free()
	fp.free()
	w.free()


## C5: driving in first person, the look eases back to the road only after 1.5 s without look input.
func _test_recentre() -> void:
	var still := FirstPersonCamera.recentred(1.0, 0.3, 0.0, 1.4, 0.1)
	var pulled := FirstPersonCamera.recentred(1.0, 0.3, 0.0, 1.5, 0.1)
	var none := FirstPersonCamera.recentred(1.0, 0.3, NAN, 9.0, 0.1)
	var w := WorldView.new()
	var fp := FirstPersonCamera.new(w)
	fp.set_look(1.0, 0.2)
	var goal: Array = [0.0]
	fp.recentre = func() -> Variant: return goal[0]
	for i in 14:   # 1.4 s still: no pull
		fp._recentre(0.1)
	var waited := is_equal_approx(fp.yaw, 1.0)
	fp._recentre(0.2)   # 1.6 s: pulls
	var eases := fp.yaw < 1.0 and fp.yaw > 0.5 and fp.pitch < 0.2
	fp.look(Vector2(-10, 0))   # the mouse moves: the wait starts again
	var y := fp.yaw
	fp._recentre(0.5)
	var reset := fp.look_idle < FirstPersonCamera.RECENTRE_AFTER and is_equal_approx(fp.yaw, y)
	fp.look_idle = 5.0
	fp.step(0.1, {"look": Vector2(0.5, 0.0)})   # the stick looks: the wait starts again
	var stick := fp.look_idle < FirstPersonCamera.RECENTRE_AFTER
	for i in 100:
		fp._recentre(0.1)
	var back := absf(fp.yaw) < 0.01 and absf(fp.pitch) < 0.01
	goal[0] = null
	fp.set_look(1.0, 0.0)
	fp._recentre(1.0)
	_check.call(still == Vector2(1.0, 0.3) and pulled.x < 1.0 and pulled.y < 0.3 and none == Vector2(1.0, 0.3)
			and waited and eases and reset and stick and back and is_equal_approx(fp.yaw, 1.0),
			"views: driving in first person the look eases back to the road after 1.5 s still; mouse or stick look starts the wait again; off: none")
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
	var d := HudSettings.new()
	d.drive = "top"
	d.save_file(path)
	var dr := HudSettings.new()
	dr.load_file(path)
	var f3 := FileAccess.open(path, FileAccess.WRITE)
	f3.store_string("[view]\ndrive=\"outside\"\n")
	f3.close()
	var dj := HudSettings.new()
	dj.drive = "first"
	dj.load_file(path)
	var f4 := FileAccess.open(path, FileAccess.WRITE)
	f4.store_string("[view]\ndrive=[\"top\"]\n")
	f4.close()
	var dk := HudSettings.new()
	dk.load_file(path)
	_check.call(HudSettings.new().drive == "chase" and dr.drive == "top" and dj.drive == "chase" and dk.drive == "chase",
			"views: the driving view is saved and read back; chase by default and for anything else in the file")
	var t := HudSettings.new()
	t.top_up = "north"
	t.recentre = false
	t.save_file(path)
	var tr := HudSettings.new()
	tr.load_file(path)
	var f5 := FileAccess.open(path, FileAccess.WRITE)
	f5.store_string("[view]\ntop_up=\"south\"\nrecentre=\"no\"\n")
	f5.close()
	var tj := HudSettings.new()
	tj.top_up = "north"
	tj.recentre = false
	tj.load_file(path)
	_check.call(HudSettings.new().top_up == "heading" and HudSettings.new().recentre and tr.top_up == "north"
			and not tr.recentre and tj.top_up == "heading" and tj.recentre,
			"views: top-down north up and the driving recentre are saved and read back; turns-with-you and on by default and for junk")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_reach_from_eyes() -> void:
	var o := Vector3(0, 5, 5)
	var d := Vector3(0, -1, -1).normalized()
	var e := Vector3(0, 1.6, 1.6)
	var moved := ViewCamera.ray_start("shoulder", o, d, e)
	_check.call(_near(moved, e) and _near(ViewCamera.ray_start("shoulder", o, d, null), o)
			and _near(ViewCamera.ray_start("shoulder", o, d, Vector3(0, 9, 9)), o)
			and _near(ViewCamera.ray_start("shoulder", o, d, Vector3(NAN, 0, 0)), o)
			and _near(ViewCamera.ray_start("first", o, d, e), o),
			"views: over the shoulder picks start where the ray passes the eyes (never behind the camera; none: the camera)")
	# top-down: a click behind the player passes the eyes' point only underground; the ray starts at eye height
	var top := ViewCamera.ray_start("top", Vector3(0, 14, 10), Vector3(0, -1, -0.2).normalized(), Vector3(0, 1.6, 0))
	_check.call(is_equal_approx(top.y, 1.6) and top.z > 7.0 and _near(ViewCamera.ray_start("top", o, Vector3.UP, e), o),
			"views: top-down picks start where the ray comes down to the eyes' height (%s)" % top)
	_check.call(_near(ViewCamera.facing(0.0), Vector3.FORWARD) and _near(ViewCamera.facing(PI / 2), Vector3.LEFT),
			"views: the facing follows the yaw (0 north, pi/2 west)")
