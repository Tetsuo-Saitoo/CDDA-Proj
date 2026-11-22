extends RefCounted
## The driving HUD (user via the coordinator, 2026-11-21): RideInfo reads player.ride (junk falls back), the speed
## gauge's scale, RideHud for the driver and a passenger, its place on small windows, and the F1 switch.

const TestDir := preload("res://tests/test_dir.gd")
const SIZES: Array[Vector2] = [Vector2(1600, 900), Vector2(1280, 720), Vector2(1024, 576), Vector2(800, 450)]
## A car at 40 mph with the throttle at 50, as lead-bridge's block sends it.
const CAR := {"name": "Sports car", "driver": true, "velocity": 4000, "cruise": 5000, "cruise_on": true,
		"safe": 6000, "max": 9000, "engine_on": true,
		"fuel": [{"id": "gasoline", "name": "gasoline", "left": 15000, "cap": 60000},
			{"id": "diesel", "name": "diesel", "left": 0, "cap": 20000}],
		"battery": [500, 1000], "skidding": false, "turn": 10, "face": 355, "mass_kg": 1500, "health": 87,
		"unit": "km/h", "unit_per_mph": 1.609344}

var _check: Callable
var _root: Node


func run(root: Node, check: Callable) -> void:
	_root = root
	_check = check
	_test_read()
	_test_junk()
	_test_gauge_scale()
	_test_settings()
	await _test_hud()
	for s in SIZES:
		await _test_place(s)


func _test_read() -> void:
	var r := RideInfo.read(CAR)
	_check.call(r.ok and r.name == "Sports car" and r.driver and r.velocity == 4000 and r.cruise == 5000 and r.cruise_on
			and r.safe == 6000 and r.top == 9000 and r.engine_on and r.fuels.size() == 2 and r.fuels[0]["left"] == 15000
			and r.battery_left == 500 and r.battery_cap == 1000 and r.mass_kg == 1500 and r.health == 87
			and r.unit == "km/h", "ride: player.ride read")
	_check.call(is_equal_approx(r.shown(4000), 64.37376) and r.band(4000) == RideInfo.Band.SAFE
			and r.band(-7000) == RideInfo.Band.WARN and r.band(9500) == RideInfo.Band.OVER and r.steer() == 15
			and r.warning() == "", "ride: km/h, the safe / warning / over bands (reverse too), steering right")
	var none := RideInfo.read(null)
	var skid := RideInfo.read({"skidding": true})
	var both := RideInfo.read({"skidding": true, "out_of_control": true, "turn": 300, "face": 20})
	_check.call(not none.ok and none.band(99999) == RideInfo.Band.SAFE and skid.ok and skid.warning() == "SKIDDING"
			and both.warning() == "OUT OF CONTROL" and both.steer() == -80 and skid.unit == "mph",
			"ride: no block, not ok; skid and out-of-control warnings; steering left; mph by default")


func _test_junk() -> void:
	var fuels := []
	for i in 20:
		fuels.append({"id": "f%d" % i, "left": 5, "cap": 10})
	var r := RideInfo.read({"name": 7, "driver": "yes", "velocity": 1e30, "cruise": NAN, "safe": -50, "max": 10,
			"engine_on": 1, "fuel": [3, {"id": "", "left": 1, "cap": 2}, {"id": "x", "left": 9, "cap": 0},
				{"id": "y", "left": 50, "cap": 20, "name": "Line\nbreak"}], "battery": [5], "turn": "left",
			"mass_kg": -3, "health": 400, "unit": "furlongs", "unit_per_mph": 2.0})
	var many := RideInfo.read({"fuel": fuels, "name": "x".repeat(500), "unit": "t/t"})
	var tt := RideInfo.read({"unit": "t/t", "unit_per_mph": 0.0025})
	var bad_k := RideInfo.read({"unit": "km/h", "unit_per_mph": INF})
	_check.call(r.ok and r.name == "" and not r.driver and r.velocity == RideInfo.MAX_VMIPH and r.cruise == 0
			and r.safe == 0 and r.top == 10 and not r.engine_on and r.fuels.size() == 1 and r.fuels[0]["left"] == 20
			and r.fuels[0]["name"] == "Line break" and r.battery_cap == -1 and r.turn == 0 and r.mass_kg == 0
			and r.health == 100 and r.unit == "mph" and r.unit_per_mph == 1.0,
			"ride: junk fields fall back, numbers clamped, bad fuel entries skipped, names one line")
	_check.call(many.fuels.size() == RideInfo.MAX_FUELS and many.name.length() == RideInfo.MAX_NAME
			and many.unit == "mph" and tt.unit == "t/t" and is_equal_approx(tt.shown(400), 0.01)
			and bad_k.unit == "km/h" and is_equal_approx(bad_k.unit_per_mph, 1.609344),
			"ride: fuel list and name capped; t/t only with the bridge's factor; a bad factor uses the unit's own")


func _test_gauge_scale() -> void:
	var r := RideInfo.read(CAR)
	var top := SpeedGauge.scale_top(r)
	var ticks := top / SpeedGauge.tick_step(top)
	var fast := RideInfo.read({"velocity": 30000, "safe": 1000, "max": 2000})
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
	var was_on := hs.ride_hud and menu.ride_check.button_pressed
	menu.ride_check.button_pressed = false
	var back := HudSettings.new()
	back.load_file(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[hud]\nride=2\n")
	f.close()
	var junk := HudSettings.new()
	junk.load_file(path)
	_check.call(was_on and not hs.ride_hud and not back.ride_hud and junk.ride_hud,
			"ride: F1 > HUD > Driving gauge is on by default, turns off and is saved; junk leaves it on")
	menu.free()


func _test_hud() -> void:
	var h := RideHud.new()
	var f := Control.new()
	f.size = Vector2(1280, 720)
	_root.add_child(f)
	f.add_child(h)
	h.visible = true
	h.show_ride(RideInfo.read(CAR))
	await _root.get_tree().process_frame
	var fuel0: Label = h._fuel_rows[0]["label"]
	var driver := h.engine_label.visible and h.engine_label.text.contains("cruise on") and fuel0.visible \
			and fuel0.text == "gasoline  25%" and (h._fuel_rows[1]["label"] as Label).visible \
			and not (h._fuel_rows[2]["label"] as Label).visible and h.battery_label.text == "Battery  50%" \
			and h.health_label.text == "Health  87%   1.5 t" and h.steer_label.visible and h.steer_label.text.contains("right") \
			and not h.warn_label.visible and h.name_label.text.contains("driving")
	var p := CAR.duplicate(true)
	p["driver"] = false
	p["skidding"] = true
	h.show_ride(RideInfo.read(p))
	await _root.get_tree().process_frame   # the gauge draws: driver, then a skidding passenger (no throttle marker)
	var passenger := h.name_label.text.contains("passenger") and h.warn_label.visible and h.warn_label.text == "SKIDDING" \
			and not h.engine_label.visible and not fuel0.visible and not h.battery_label.visible \
			and not h.health_label.visible and not h.steer_label.visible
	h.show_ride(RideInfo.read({"velocity": -500, "driver": true}))   # reversing, no engine data: a grey scale
	await _root.get_tree().process_frame
	_check.call(driver and passenger and RideHud.mass_text(850) == "850 kg",
			"%s | %s | %s | %s" % [h.engine_label.text, fuel0.text, h.battery_label.text, h.health_label.text] if not driver else
			"ride HUD: the driver sees engine, cruise, fuel, battery, health, mass and steering; a passenger the name and warnings")
	f.free()


## The dash in the window, off the hands panel (bottom right, 400 wide) and the HUD's left column.
func _test_place(s: Vector2) -> void:
	var h := RideHud.new()
	var f := Control.new()
	f.size = s
	_root.add_child(f)
	f.add_child(h)
	h.visible = true
	h.show_ride(RideInfo.read(CAR))
	await _root.get_tree().process_frame
	var hands := Rect2(s.x - 410.0, s.y - 96.0, 400.0, 86.0)
	var column := Rect2(12.0, s.y / 2.0 - 140.0, 560.0, 230.0)
	var text := Rect2(10.0, 50.0, s.x - 22.0, 52.0)
	h.place([hands, column, text] as Array[Rect2])
	var r := Rect2(h.dash.global_position, h.dash.size * h.dash.scale.x)
	var inside := Rect2(Vector2.ZERO, s).grow(1.0).encloses(r)
	var clear := not r.intersects(hands) and not r.intersects(text)
	var off_column := not r.intersects(column) or s.x < 1000.0   # a small window may have to cover some of it
	_check.call(inside and clear and off_column and h.dash.scale.x >= RideHud.MIN_SCALE - 0.001,
			"ride HUD %dx%d: in the window, off the hands panel and the text%s (%s, scale %.2f)" % [s.x, s.y,
			"" if s.x < 1000.0 else " and the left column", r, h.dash.scale.x])
	f.free()
