extends RefCounted
## The driving HUD (user via the coordinator, 2026-11-21): RideInfo reads player.vehicle_state (junk falls back), the speed
## gauge's scale, RideHud for the driver and a passenger, its place on small windows, and the F1 switch.

const TestDir := preload("res://tests/test_dir.gd")
const SIZES: Array[Vector2] = [Vector2(1600, 900), Vector2(1280, 720), Vector2(1024, 576), Vector2(800, 450)]
## A car at 40 mph set to reach 50, as lead-bridge's player.vehicle_state sends it (itype 7 gasoline, 8 diesel).
const CAR := {"uid": 8589934864, "name": "Station Wagon", "in_control": true, "at_controls": true,
		"velocity": 4000, "cruise_velocity": 5000, "safe_velocity": 6000, "max_velocity": 9000,
		"speed_unit": "km/h", "speed_scale": 0.01609344, "engine_on": true,
		"engines": [[12, 3, 255, 7], [13, 4, 0, 7]], "fuels": [[7, 15000, 60000], [8, 0, 20000]],
		"battery": [500, 1000], "turn_deg": 10.0, "skidding": false, "mass_kg": 1500, "health_pct": 87}
const FACE := 355.0


static func _fuel_name(t: int) -> String:
	return {7: "gasoline", 8: "diesel"}.get(t, "")


var _check: Callable
var _root: Node


func run(root: Node, check: Callable, data: Variant) -> void:
	_root = root
	_check = check
	_test_snapshot(data)
	_test_compass_view()
	_test_shown()
	_test_read()
	_test_junk()
	_test_gauge_scale()
	_test_settings()
	await _test_hud()
	for s in SIZES:
		await _test_place(s, true, false)
		await _test_place(s, false, false)
		await _test_place(s, false, true)


## Snapshot keeps player.vehicle_state as sent; on foot, not an object or over 32 keys it's {}, the snapshot stays.
func _test_snapshot(data: Variant) -> void:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var pl: Dictionary = d["player"]
	pl["vehicle_state"] = CAR.duplicate(true)
	var on := Snapshot.from_data(d)
	var big := {}
	for i in 33:
		big["k%d" % i] = i
	var junk_ok := true
	for bad: Variant in ["car", [1, 2], 5, big]:
		pl["vehicle_state"] = bad
		var j := Snapshot.from_data(d)
		junk_ok = junk_ok and j.is_valid() and j.player_vehicle_state.is_empty()
	pl.erase("vehicle_state")
	var off := Snapshot.from_data(d)
	_check.call(on.is_valid() and on.player_vehicle_state.get("name") == "Station Wagon" and junk_ok
			and off.is_valid() and off.player_vehicle_state.is_empty(),
			"ride: the snapshot keeps player.vehicle_state; on foot, junk or over 32 keys it's empty, the snapshot stays")


## The flat compass reads the camera on screen (a chase camera while driving), else the player's view.
func _test_compass_view() -> void:
	var Main := load("res://scripts/main.gd")
	var eyes := Node3D.new()
	var cam := Camera3D.new()
	cam.basis = Basis(Vector3.UP, deg_to_rad(-90.0))
	var chosen: Node3D = Main.drawn_view(cam, eyes)
	var heading := Compass.heading_of(chosen.basis)
	_check.call(chosen == cam and not is_equal_approx(heading, Compass.heading_of(eyes.basis))
			and Main.drawn_view(null, eyes) == eyes,
			"ride: the compass follows the camera on screen; with none, the player's view")
	cam.free()
	eyes.free()


## The HUD shows on a vehicle; at the controls in first person only with F1's switch; a passenger always.
func _test_shown() -> void:
	var Main := load("res://scripts/main.gd")
	var hs := HudSettings.new()
	var drv := RideInfo.read(CAR)
	var p := CAR.duplicate(true)
	p["in_control"] = false
	var parked := RideInfo.read(p)   # at the controls, not driving
	p["at_controls"] = false
	var pas := RideInfo.read(p)
	var out: Array[bool] = [Main.ride_shown(drv, hs, false), Main.ride_shown(drv, hs, true),
			Main.ride_shown(parked, hs, true), Main.ride_shown(pas, hs, true), Main.ride_shown(RideInfo.read(null), hs, false)]
	hs.ride_hud_fp = true
	out.append(Main.ride_shown(drv, hs, true))
	hs.ride_hud = false
	out.append(Main.ride_shown(drv, hs, false))
	_check.call(out == [true, false, false, true, false, true, false],
			"ride: the HUD shows on a vehicle; at the controls in first person (driving or not) only when F1 says so; "
			+ "a passenger seat shows it; off is off (%s)" % [out])


func _test_read() -> void:
	var r := RideInfo.read(CAR, _fuel_name, FACE)
	_check.call(r.ok and r.uid == 8589934864 and r.name == "Station Wagon" and r.driver and r.at_controls
			and r.velocity == 4000 and r.cruise == 5000 and r.safe == 6000 and r.top == 9000 and r.engine_on
			and r.engines == 2 and r.engines_running == 1 and r.engines_broken == 1 and r.fuels.size() == 2
			and r.fuels[0]["name"] == "gasoline" and r.fuels[0]["left"] == 15000 and r.battery_left == 500
			and r.battery_cap == 1000 and r.mass_kg == 1500 and r.health == 87 and r.unit == "km/h",
			"ride: player.vehicle_state read (engines running and broken, fuel names from the item table)")
	_check.call(is_equal_approx(r.shown(4000), 64.37376) and r.band(4000) == RideInfo.Band.SAFE
			and r.band(-7000) == RideInfo.Band.WARN and r.band(9500) == RideInfo.Band.OVER and r.steer() == 15
			and r.warning() == "" and r.health_word() == "dented" and r.set_speed() == 5000
			and RideInfo.read({"cruise_velocity": 5000, "engine_on": false}).set_speed() == 0,
			"ride: km/h, the safe / strain / over bands (backwards too), steering right, CDDA's condition word; "
			+ "the set speed rests at 0 with the engine off")
	var none := RideInfo.read(null)
	var skid := RideInfo.read({"skidding": true, "turn_deg": 300.0, "health_pct": 0})
	var left := RideInfo.read({"turn_deg": 300}, Callable(), 20.0)
	var words := PackedStringArray()
	for h in [100, 96, 95, 68, 35, 34, 1]:
		words.append(RideInfo.read({"health_pct": h}).health_word())
	_check.call(not none.ok and none.band(99999) == RideInfo.Band.SAFE and skid.ok and skid.warning() == "SKIDDING"
			and skid.steer() == 0 and left.steer() == -80 and skid.unit == "mph" and skid.health_word() == "destroyed"
			and words == PackedStringArray(["like new", "like new", "dented", "dented", "battered", "wrecked",
			"wrecked"]) and RideInfo.read({}).health_word() == "",
			"ride: no block, not ok; the skid warning; steering only with the facing; mph by default; condition words")


func _test_junk() -> void:
	var fuels := []
	for i in 40:
		fuels.append([i + 1, 5, 10])
	var r := RideInfo.read({"name": 7, "in_control": "yes", "velocity": 1e30, "cruise_velocity": NAN,
			"safe_velocity": -50, "max_velocity": 10, "engine_on": 1, "engines": [3, [1], [1, "x"], [1, 6, 0, 0]],
			"fuels": [3, [0, 1, 2], [9, 1, 0], [9, 50, 20], [9, 1, 2, 3]], "battery": [0, 0], "turn_deg": "left",
			"mass_kg": -3, "health_pct": 400, "speed_unit": "furlongs", "speed_scale": 2.0},
			func(_t: int) -> String: return "Line\nbreak", INF)
	var many := RideInfo.read({"fuels": fuels, "name": "x".repeat(500), "speed_unit": "t/t"})
	var tt := RideInfo.read({"speed_unit": "t/t", "speed_scale": 0.0025})
	var bad_k := RideInfo.read({"speed_unit": "km/h", "speed_scale": INF})
	var no_names := RideInfo.read({"fuels": [[5, 1, 2]]}, func(_t: int) -> Variant: return 12)
	_check.call(r.ok and r.name == "" and not r.driver and r.velocity == RideInfo.MAX_VMIPH and r.cruise == 0
			and r.safe == 0 and r.top == 10 and not r.engine_on and r.engines == 1 and r.engines_broken == 1
			and r.engines_running == 1 and r.fuels.size() == 1 and r.fuels[0]["left"] == 20
			and r.fuels[0]["name"] == "Line break" and r.battery_cap == -1 and is_nan(r.turn_deg) and is_nan(r.face_deg)
			and r.mass_kg == 0 and r.health == 100 and r.unit == "mph" and r.scale == 0.01
			and no_names.fuels[0]["name"] == "fuel",
			"ride: junk fields fall back, numbers clamped, bad engine and fuel entries skipped, names one line")
	_check.call(many.fuels.size() == RideInfo.MAX_FUELS and many.name.length() == RideInfo.MAX_NAME
			and many.unit == "t/t" and is_equal_approx(many.scale, 0.0025) and is_equal_approx(tt.shown(400), 1.0)
			and bad_k.unit == "km/h" and is_equal_approx(bad_k.scale, 0.01609344),
			"ride: fuel rows and name capped; a bad speed_scale uses the unit's own")


func _test_gauge_scale() -> void:
	var r := RideInfo.read(CAR, _fuel_name, FACE)
	var top := SpeedGauge.scale_top(r)
	var ticks := top / SpeedGauge.tick_step(top)
	var fast := RideInfo.read({"velocity": 30000, "safe_velocity": 1000, "max_velocity": 2000})
	_check.call(top >= r.shown(r.top) * 1.15 and ticks >= 4.0 and ticks <= 8.0 and is_equal_approx(fmod(top,
			SpeedGauge.tick_step(top)), 0.0) and SpeedGauge.scale_top(fast) >= 300.0
			and is_equal_approx(SpeedGauge.angle_of(0.0, top), deg_to_rad(150.0))
			and is_equal_approx(SpeedGauge.angle_of(top * 2.0, top), deg_to_rad(390.0))
			and is_equal_approx(SpeedGauge.angle_of(-top / 2.0, top), deg_to_rad(270.0))
			and is_equal_approx(SpeedGauge.angle_of(5.0, 0.0), deg_to_rad(150.0)),
			"ride gauge: the scale passes the top speed on round ticks (4 to 8), holds any speed; angles clamp")


func _test_settings() -> void:
	var path := TestDir.path("ride_hud.cfg")
	var hs := HudSettings.new()
	var menu := KeyMenu.new()
	menu.add_hud_settings(hs, path)
	var was_on := hs.ride_hud and menu.ride_check.button_pressed and not hs.ride_hud_fp \
			and not menu.ride_fp_check.button_pressed
	menu.ride_check.button_pressed = false
	menu.ride_fp_check.button_pressed = true
	var back := HudSettings.new()
	back.load_file(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[hud]\nride=2\nride_first_person=\"yes\"\n")
	f.close()
	var junk := HudSettings.new()
	junk.load_file(path)
	_check.call(was_on and not hs.ride_hud and not back.ride_hud and junk.ride_hud and hs.ride_hud_fp
			and back.ride_hud_fp and not junk.ride_hud_fp,
			"ride: F1 > HUD > Driving gauge on and Gauge in first person off by default, both saved; junk: the defaults")
	menu.free()


func _test_hud() -> void:
	var h := RideHud.new()
	var f := Control.new()
	f.size = Vector2(1280, 720)
	_root.add_child(f)
	f.add_child(h)
	h.visible = true
	h.show_ride(RideInfo.read(CAR, _fuel_name, FACE))
	await _root.get_tree().process_frame
	var fuel0: Label = h._fuel_rows[0]["label"]
	var driver := h.engine_label.visible and h.engine_label.text == "Engine on  (1 of 2 broken)" and fuel0.visible \
			and fuel0.text == "gasoline  25%" and (h._fuel_rows[1]["label"] as Label).visible \
			and not (h._fuel_rows[2]["label"] as Label).visible and h.battery_label.text == "Battery  50%" \
			and h.health_label.text == "Health  87% (dented)   1.5 t" and h.steer_label.visible and h.steer_label.text.contains("right") \
			and not h.warn_label.visible and h.name_label.text.contains("driving")
	var p := CAR.duplicate(true)
	p["in_control"] = false
	p["skidding"] = true
	h.show_ride(RideInfo.read(p, _fuel_name, FACE))
	await _root.get_tree().process_frame   # the gauge draws: driver, then a skidding passenger (no throttle marker)
	var passenger := h.name_label.text.contains("passenger") and h.warn_label.visible and h.warn_label.text == "SKIDDING" \
			and not h.engine_label.visible and not fuel0.visible and not h.battery_label.visible \
			and not h.health_label.visible and not h.steer_label.visible
	h.show_ride(RideInfo.read({"velocity": -500, "in_control": true}))   # reversing, no engine data: a grey scale
	await _root.get_tree().process_frame
	_check.call(driver and passenger and RideHud.mass_text(850) == "850 kg",
			"%s | %s | %s | %s" % [h.engine_label.text, fuel0.text, h.battery_label.text, h.health_label.text] if not driver else
			"ride HUD: the driver sees engines, fuel, battery, condition, mass and steering; a passenger the name and warnings")
	f.free()


## The dash in the window, off the hands panel (bottom right, 400 wide), the HUD's text and its left column moved
## down under a status text: beside the feed's six messages, or with messages too wide for that the feed shows
## fewer lines.
func _test_place(s: Vector2, with_hands: bool, wide: bool) -> void:
	var h := RideHud.new()
	var hv := HudView.new()
	var hd := HudData.new()
	var f := Control.new()
	f.size = s
	_root.add_child(f)
	f.add_child(hv)
	f.add_child(h)
	hv.data = hd
	var ev: Array = []
	for i in HudView.FEED_LINES:
		ev.append({"kind": "message", "text": "A long line of the message feed, number %d, as wide as they come" % i
				+ (" and wider still".repeat(6) if wide else "")})
	hd.on_events(ev)
	h.visible = true
	h.show_ride(RideInfo.read(CAR, _fuel_name, FACE))
	await _root.get_tree().process_frame
	hv.avoid(Rect2(Vector2.ZERO, s * Vector2(1.0, 0.6)))   # a long status text: the left column moves down
	var hands := Rect2(s.x - 410.0, s.y - 96.0, 400.0, 86.0) if with_hands else Rect2()
	var text := Rect2(10.0, 50.0, s.x - 22.0, 52.0)
	var full := hv.column_rect(true)
	h.place([hands, full, text] as Array[Rect2], hands)
	hv.keep_feed_above(h.dash_rect())
	var r := h.dash_rect()
	var lines := hv.feed.text.split("\n").size()
	var inside := Rect2(Vector2.ZERO, s).grow(1.0).encloses(r)
	var clear := not r.intersects(hands) and not r.intersects(text) and not r.intersects(hv.column_rect())
	var cut := r.intersects(full) == (lines < HudView.FEED_LINES) and lines >= 1
	cut = cut and (lines < HudView.FEED_LINES if wide and s.x <= 1280.0 else lines == HudView.FEED_LINES)
	hv.keep_feed_above(Rect2())
	var back := hv.feed.text.split("\n").size() == HudView.FEED_LINES
	_check.call(inside and clear and cut and back and h.dash.scale.x >= RideHud.MIN_SCALE - 0.001,
			"ride HUD %dx%d%s: in the window, off the hands panel, the text and the left column; the feed shows %d "
			% [s.x, s.y, ("" if with_hands else " (hands empty)") + (" (wide feed)" if wide else ""), lines] + "lines under it, all again without it (%s, column %s, scale %.2f)" % [r,
			hv.column_rect(), h.dash.scale.x])
	f.free()
