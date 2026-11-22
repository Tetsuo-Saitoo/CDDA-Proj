class_name KeyMenu
extends PanelContainer
## Key menu (F1): every action with two key slots and a pad slot. Click a key slot, then press a key or mouse
## button (modifiers count: Shift+E is its own key; a modifier alone binds when let go); click the pad slot,
## then press a pad button or push a stick / trigger one way. Esc cancels, Backspace clears the slot. Each change is saved at once (InputActions.save_bindings); a key that another action also uses is
## kept on both and named in the status line. While open the menu takes every key, so nothing reaches the game.
## With a pad: the D-pad or left stick picks a slot (highlighted), A starts setting it, B / Back / Start close,
## X swaps in the Cheats page (when it may show), where the D-pad, stick and A work its controls (CheatPanel.pad_*;
## the VR stick's ui_* actions too).
## With add_hud_settings() it also has the HUD row (compass opacity slider, the debug-cheats switch), saved in
## user://hud.cfg, and the G7 options rows (look speed, field of view, 3D resolution, fullscreen, vsync; main applies
## them on hud_changed). With add_cheat_page() a "Cheats" button swaps the key list for the CheatPanel; it shows only
## while cheats are allowed (the debug switch, or cheats_forced by --test / --cheats).

signal closed
signal hud_changed   # a HudSettings value changed (and was saved)
signal quit_to_menu   # "Save and quit to menu" pressed (main.gd: CDDA's save and quit)

const SLOTS := 2
const PAD_SLOTS := 2
const MARGIN := Vector2(60, 50)          # px around the menu; less on a small window (MARGIN_SHARE of it)
const MARGIN_SHARE := Vector2(0.047, 0.07)
const SETTINGS_SHARE := 0.45   # of the menu's height, at most, for the settings rows (the rest: the key list)
const LIST_MIN_H := 80.0       # px the key list (or the Cheats page) keeps at least, when the window allows
const LABEL_MIN_W := 160.0     # an action's text wraps down to this
const PAD_SLOT := SLOTS   # slot index of the first pad column (more bindings than columns show as +N)
const LAST_SLOT := SLOTS + PAD_SLOTS - 1
const WARN := Color(1.0, 0.75, 0.3)

var save_path := InputActions.FILE
var _buttons := {}            # action -> [key Button, key Button, pad Button, pad Button]
var _status: Label
var _capture: Array = []      # [action, slot] while waiting for a key
var _pending_mod := KEY_NONE  # a modifier pressed while capturing, bound alone if let go first
var _box: VBoxContainer
var hud: HudSettings          # set by add_hud_settings
var real_time_check: CheckBox   # the Time row (ClockControl)
var auto_pause_check: CheckBox
var hud_path := HudSettings.FILE
var compass_slider: HSlider
var _compass_value: Label
var debug_check: CheckBox
var mood_check: CheckBox
var hurt_check: CheckBox
var ride_check: CheckBox   # HUD row: the driving HUD on a vehicle
var key_help_check: CheckBox   # HUD row: the key help along the top, or one short line
var flash_check: CheckBox
## G1: the message feed's filter, one box per HudSettings.FEED_GROUPS group (checked = shown).
var feed_checks := {}
var eye_checks := {}   # HudSettings.EYE_FEATURES id -> its CheckBox
## G7 options (HudSettings look_speed, invert_y, fov, render_scale, ui_scale, fullscreen, vsync, weather_quality).
var look_slider: HSlider
var invert_check: CheckBox
var ui_slider: HSlider
var weather_pick: OptionButton
var menu_pick: OptionButton   # HudSettings.context_menu: how E shows an object's choices
var main_pick: OptionButton   # HudSettings.main_hand, in MAIN_HANDS' order
var volume_slider: HSlider
var ambience_slider: HSlider
## G6 (add_hints): the hints and their on / off box.
var hints: Hints
var hints_check: CheckBox
var hints_again: Button
var fov_slider: HSlider
var scale_slider: HSlider
var fullscreen_check: CheckBox
var vsync_check: CheckBox
var _option_values := {}   # option key -> the Label after its slider
const FEED_TIPS := {
	"good": "Good things that happen to you: healing, learning, a good find.",
	"bad": "Bad or mixed things that happen to you: hits, pain, a skill getting rusty.",
	"warning": "Dangers: a monster comes into view, an alarm, a noise.",
	"info": "What you examine or look at, how something works.",
	"other": "Everything else: misses, small things.",
}
var cheat_page: CheatPanel    # set by add_cheat_page
var cheat_scroll: ScrollContainer   # holds it: the page scrolls when taller than the menu (small window, VR panel)
var cheats_button: Button
## "Save and quit to menu": shown with show_quit_to_menu (a live game); closes the menu and emits quit_to_menu.
var quit_button: Button
## --test / --cheats: the Cheats page is there this session whatever the debug switch says.
var cheats_forced := false:
	set(v):
		cheats_forced = v
		if cheats_button != null:
			_update_cheats_button()
var _title: Label
var _scroll: ScrollContainer
var _settings_scroll: ScrollContainer   # the HUD / options rows: scroll when taller than SETTINGS_SHARE of the menu
var _settings: VBoxContainer
## The slot picked with the pad: (row in InputActions.ACTIONS, slot); row -1 = none picked yet.
var cursor := Vector2i(-1, PAD_SLOT)
var _axis_held := {}   # stick axis -> -1 / 0 / 1 as last pushed: one step per push
const PICKED := Color(1.0, 0.8, 0.35)
## ui_* actions that work the Cheats page's controls (the VR stick) -> their step.
const CHEAT_ACTIONS := {&"ui_up": -1, &"ui_down": 1, &"ui_left": -1, &"ui_right": 1, &"ui_accept": 0}
const KEYS_TITLE := ("Keys: click a slot, then press a key or mouse button (pad column: a pad button or stick).  "
		+ "Esc cancels  Backspace clears  F1 / Esc closes.  Pad: D-pad picks, A sets, B / Start closes.  "
		+ "In the game Esc / Start backs out of one thing per press, then opens this menu")


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = MARGIN.x
	offset_top = MARGIN.y
	offset_right = -MARGIN.x
	offset_bottom = -MARGIN.y
	visible = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.08, 0.1, 0.96)
	bg.set_content_margin_all(12)
	add_theme_stylebox_override("panel", bg)
	var box := VBoxContainer.new()
	_box = box
	add_child(box)
	var title := Label.new()
	title.text = KEYS_TITLE
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # a narrow window wraps it, not the menu
	_title = title
	box.add_child(title)
	_settings_scroll = ScrollContainer.new()
	_settings_scroll.name = "SettingsScroll"
	_settings_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_settings_scroll)
	_settings = VBoxContainer.new()
	_settings.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_scroll.add_child(_settings)
	_settings.minimum_size_changed.connect(_fit_settings)
	box.minimum_size_changed.connect(_fit_settings, CONNECT_DEFERRED)   # the title or bar wrapped: refit
	resized.connect(_fit_settings)
	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO   # the key columns scroll sideways on a narrow window
	box.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 1 + SLOTS + PAD_SLOTS
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	var group := ""
	for a: Array in InputActions.ACTIONS:
		if a[1] != group:
			group = a[1]
			for i in grid.columns:
				var h := Label.new()
				h.text = group if i == 0 else ("pad" if i == 1 + SLOTS else "")
				h.add_theme_color_override("font_color", WARN)
				grid.add_child(h)
		var l := Label.new()
		l.text = a[2]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # a narrow window wraps the text, not the menu
		l.custom_minimum_size = Vector2(LABEL_MIN_W, 0)
		grid.add_child(l)
		var row: Array[Button] = []
		for s in SLOTS + PAD_SLOTS:
			var b := Button.new()
			b.custom_minimum_size = Vector2(140 if s < SLOTS else 110, 0)
			b.focus_mode = Control.FOCUS_NONE
			b.pressed.connect(start_capture.bind(a[0], s))
			grid.add_child(b)
			row.append(b)
		_buttons[a[0]] = row
	var bar := HFlowContainer.new()   # wraps on a narrow window
	box.add_child(bar)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bar.add_child(_status)
	cheats_button = Button.new()
	cheats_button.text = "Cheats"
	cheats_button.focus_mode = Control.FOCUS_NONE
	cheats_button.visible = false
	cheats_button.pressed.connect(func() -> void: show_cheats(not showing_cheats()))
	bar.add_child(cheats_button)
	quit_button = Button.new()
	quit_button.text = "Save and quit to menu"
	quit_button.focus_mode = Control.FOCUS_NONE
	quit_button.visible = false
	quit_button.pressed.connect(func() -> void:
		close()
		quit_to_menu.emit())
	bar.add_child(quit_button)
	for t: String in ["Reset all", "Close"]:
		var b := Button.new()
		b.text = t
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(reset_all if t == "Reset all" else close)
		bar.add_child(b)


func show_quit_to_menu(on: bool) -> void:
	quit_button.visible = on


## Adds the HUD row under the title: compass opacity 0..100 %.
func add_hud_settings(settings: HudSettings, path := HudSettings.FILE) -> void:
	hud = settings
	hud_path = path
	var row := HFlowContainer.new()
	var l := Label.new()
	l.text = "HUD   compass opacity"
	row.add_child(l)
	compass_slider = HSlider.new()
	compass_slider.min_value = HudSettings.MIN_COMPASS_OPACITY
	compass_slider.max_value = 1.0
	compass_slider.step = 0.05
	compass_slider.custom_minimum_size = Vector2(220, 0)
	compass_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	compass_slider.focus_mode = Control.FOCUS_NONE   # keys stay with the menu
	compass_slider.value = settings.compass_opacity
	compass_slider.value_changed.connect(_on_compass_opacity)
	row.add_child(compass_slider)
	_compass_value = Label.new()
	row.add_child(_compass_value)
	mood_check = CheckBox.new()
	mood_check.text = "Mood tint"
	mood_check.tooltip_text = "Tints the edges of the view when your character's mood is low or high."
	mood_check.focus_mode = Control.FOCUS_NONE
	mood_check.button_pressed = settings.mood_cues
	mood_check.toggled.connect(_on_mood_cues)
	row.add_child(mood_check)
	hurt_check = CheckBox.new()
	hurt_check.text = "Hurt tint"
	hurt_check.tooltip_text = "Darkens the edges of the view red when you are hit or bleeding."
	hurt_check.focus_mode = Control.FOCUS_NONE
	hurt_check.button_pressed = settings.hurt_cues
	hurt_check.toggled.connect(_on_hurt_cues)
	row.add_child(hurt_check)
	flash_check = CheckBox.new()
	flash_check.text = "Bright flashes"
	flash_check.tooltip_text = "Lightning and muzzle flashes. Off: thunder and recoil only."
	flash_check.focus_mode = Control.FOCUS_NONE
	flash_check.button_pressed = settings.weather_flash
	flash_check.toggled.connect(_on_weather_flash)
	row.add_child(flash_check)
	key_help_check = CheckBox.new()
	key_help_check.text = "Key help"
	key_help_check.tooltip_text = "The keys along the top of the screen. Off: one short line (this menu lists them all)."
	key_help_check.focus_mode = Control.FOCUS_NONE
	key_help_check.button_pressed = settings.key_help
	key_help_check.toggled.connect(_on_key_help)
	row.add_child(key_help_check)
	ride_check = CheckBox.new()
	ride_check.text = "Driving gauge"
	ride_check.tooltip_text = "The speed gauge and the vehicle's fuel, battery and health while you're on a vehicle."
	ride_check.focus_mode = Control.FOCUS_NONE
	ride_check.button_pressed = settings.ride_hud
	ride_check.toggled.connect(_on_ride_hud)
	row.add_child(ride_check)
	debug_check = CheckBox.new()
	debug_check.text = "Debug: cheats page"
	debug_check.tooltip_text = "Shows the Cheats button here (testing only; off by default)."
	debug_check.focus_mode = Control.FOCUS_NONE
	debug_check.button_pressed = settings.debug_cheats
	debug_check.toggled.connect(_on_debug_cheats)
	row.add_child(debug_check)
	_put_setting(row, 0)
	var feed_row := HFlowContainer.new()
	var fl := Label.new()
	fl.text = "Messages shown"
	feed_row.add_child(fl)
	for g: String in HudSettings.FEED_GROUPS:
		var c := CheckBox.new()
		c.text = HudSettings.FEED_GROUPS[g]
		c.tooltip_text = FEED_TIPS[g]
		c.focus_mode = Control.FOCUS_NONE
		c.button_pressed = not settings.feed_hidden.has(g)
		c.toggled.connect(_on_feed_group.bind(g))
		feed_checks[g] = c
		feed_row.add_child(c)
	_put_setting(feed_row, 1)
	var opt_row := HFlowContainer.new()
	var ol := Label.new()
	ol.text = "Look speed"
	opt_row.add_child(ol)
	look_slider = _option_slider(opt_row, HudSettings.LOOK_SPEEDS, 0.05, settings.look_speed, &"look_speed")
	look_slider.tooltip_text = "How far the view turns for a mouse move."
	invert_check = _option_check(opt_row, "Invert Y", "Moving the mouse up looks down.", &"invert_y",
			settings.invert_y)
	main_pick = OptionButton.new()
	for h: String in HudSettings.MAIN_HANDS:
		main_pick.add_item("%s-handed" % h.capitalize())
	main_pick.tooltip_text = ("Your main hand: the keys for the left and right hand strike with that hand, and the gun "
			+ "rests on that side. The headset has its own in its menu.")
	main_pick.focus_mode = Control.FOCUS_NONE
	main_pick.select(maxi(HudSettings.MAIN_HANDS.find(settings.main_hand), 0))
	main_pick.item_selected.connect(func(i: int) -> void:
		if i >= 0 and i < HudSettings.MAIN_HANDS.size():
			set_option(&"main_hand", HudSettings.MAIN_HANDS[i]))
	opt_row.add_child(main_pick)
	menu_pick = OptionButton.new()
	for n: String in HudSettings.MENU_NAMES:
		menu_pick.add_item(n)
	menu_pick.tooltip_text = ("How E shows an object's choices (a sink: drink, fill, empty, wash): a wheel where each "
			+ "choice has its own place, picked by letting go of E or by a click, or the game's list.")
	menu_pick.focus_mode = Control.FOCUS_NONE
	menu_pick.select(clampi(settings.context_menu, 0, HudSettings.MENU_NAMES.size() - 1))
	menu_pick.item_selected.connect(func(i: int) -> void: set_option(&"context_menu", i))
	opt_row.add_child(menu_pick)
	var vl := Label.new()
	vl.text = "Field of view"
	opt_row.add_child(vl)
	fov_slider = _option_slider(opt_row, HudSettings.FOVS, 1.0, settings.fov, &"fov")
	fov_slider.tooltip_text = "How wide the view is, in degrees across the screen's height."
	_put_setting(opt_row, 2)
	var disp_row := HFlowContainer.new()
	var sl := Label.new()
	sl.text = "3D resolution"
	disp_row.add_child(sl)
	scale_slider = _option_slider(disp_row, HudSettings.RENDER_SCALES, 0.05, settings.render_scale, &"render_scale")
	scale_slider.tooltip_text = "Lower draws the world with fewer pixels: faster, softer. The menus stay sharp."
	var ul := Label.new()
	ul.text = "Menu size"
	disp_row.add_child(ul)
	ui_slider = _option_slider(disp_row, HudSettings.UI_SCALES, 0.05, settings.ui_scale, &"ui_scale")
	ui_slider.tooltip_text = "The size of the menus and the HUD. Applies when this menu closes."
	fullscreen_check = _option_check(disp_row, "Fullscreen", "Fills the screen (off: a window).", &"fullscreen",
			settings.fullscreen)
	vsync_check = _option_check(disp_row, "Vsync", "Waits for the screen: no tearing. Off can be faster but tears.",
			&"vsync", settings.vsync)
	var wl := Label.new()
	wl.text = "Weather"
	disp_row.add_child(wl)
	weather_pick = OptionButton.new()
	for n: String in WeatherView.QUALITY_NAMES:   # index = WeatherView.MINIMAL, LOW, HIGH
		weather_pick.add_item(n.capitalize())
	weather_pick.tooltip_text = ("How much rain, snow and cloud is drawn. Low and Minimal are lighter on the GPU; the "
			+ "darker light, the fog and the sound stay.")
	weather_pick.focus_mode = Control.FOCUS_NONE
	weather_pick.select(clampi(settings.weather_quality, 0, WeatherView.QUALITY_NAMES.size() - 1))
	weather_pick.item_selected.connect(func(i: int) -> void: set_option(&"weather_quality", i))
	disp_row.add_child(weather_pick)
	_put_setting(disp_row, 3)
	var sound_row := HFlowContainer.new()
	var vol := Label.new()
	vol.text = "Volume"
	sound_row.add_child(vol)
	volume_slider = _option_slider(sound_row, HudSettings.VOLUMES, 0.05, settings.volume, &"volume")
	volume_slider.tooltip_text = "How loud the game is: weather, hits, shots, explosions. 0 is silent."
	var aml := Label.new()
	aml.text = "Weather sounds"
	sound_row.add_child(aml)
	ambience_slider = _option_slider(sound_row, HudSettings.VOLUMES, 0.05, settings.ambience_volume,
			&"ambience_volume")
	ambience_slider.tooltip_text = "Rain, wind and thunder, under the volume on the left."
	_put_setting(sound_row, 4)
	var eye_row := HFlowContainer.new()   # eye tracking: one box per feature (HudSettings.EYE_FEATURES)
	var el := Label.new()
	el.text = "Eye tracking"
	eye_row.add_child(el)
	for id: String in HudSettings.EYE_FEATURES:
		var f: Array = HudSettings.EYE_FEATURES[id]
		var c := CheckBox.new()
		c.text = f[0]
		c.tooltip_text = f[2]
		c.focus_mode = Control.FOCUS_NONE
		c.button_pressed = settings.eye_switch(id)
		c.toggled.connect(_on_eye.bind(id))
		eye_checks[id] = c
		eye_row.add_child(c)
	_put_setting(eye_row, 5)
	var clock_row := HFlowContainer.new()   # real time or turns (ClockControl)
	var tl := Label.new()
	tl.text = "Time"
	clock_row.add_child(tl)
	real_time_check = _clock_box(clock_row, "Real time", settings.real_time, _on_real_time,
			"On: the game runs on its own, a second a turn. Off: it waits for you each turn. VR always runs in real time.")
	auto_pause_check = _clock_box(clock_row, "Pause when a hostile comes into view", settings.auto_pause,
			_on_auto_pause, "Real time only. The time pause key goes on.")
	_put_setting(clock_row, 6)
	_show_eyes()
	_show_compass_value()
	_show_options()


## G6: the Hints row under the options: show hints on / off, and "Show hints again" (Hints.reset).
func add_hints(h: Hints) -> void:
	hints = h
	var row := HFlowContainer.new()
	hints_check = CheckBox.new()
	hints_check.text = "Hints"
	hints_check.tooltip_text = "Short tips the first time you meet something (each shows once)."
	hints_check.focus_mode = Control.FOCUS_NONE
	hints_check.button_pressed = h.enabled
	hints_check.toggled.connect(func(on: bool) -> void: hints.set_enabled(on))
	row.add_child(hints_check)
	hints_again = Button.new()
	hints_again.text = "Show hints again"
	hints_again.focus_mode = Control.FOCUS_NONE
	hints_again.pressed.connect(func() -> void:
		hints.reset()
		_status.text = "Each hint shows once more.")
	row.add_child(hints_again)
	_put_setting(row, 5)


## A settings row at place `at` among them (clamped: rows come in any order).
func _put_setting(row: Control, at: int) -> void:
	_settings.add_child(row)
	_settings.move_child(row, mini(at, _settings.get_child_count() - 1))


## The settings rows take their own height, but at most SETTINGS_SHARE of the menu: on a small window they scroll
## and the key list (or the Cheats page) keeps the rest.
func _fit_settings() -> void:
	if _settings == null:
		return
	var avail := size.y   # the menu's height when nothing in it overflows (not its size: that grows with it)
	if is_inside_tree():
		var area := get_parent_area_size()
		var m := Vector2(minf(MARGIN.x, roundf(area.x * MARGIN_SHARE.x)), minf(MARGIN.y, roundf(area.y * MARGIN_SHARE.y)))
		if not is_equal_approx(offset_left, m.x) or not is_equal_approx(offset_top, m.y):
			offset_left = m.x
			offset_right = -m.x
			offset_top = m.y
			offset_bottom = -m.y
		avail = area.y - 2.0 * m.y
	var want := _settings.get_combined_minimum_size().y
	var cap := want
	if avail > 0.0:   # the title, buttons and margins keep their room, and the list LIST_MIN_H
		var others := get_combined_minimum_size().y - _settings_scroll.get_combined_minimum_size().y
		cap = maxf(minf(avail * SETTINGS_SHARE, avail - others - LIST_MIN_H), 60.0)
	_settings_scroll.custom_minimum_size.y = minf(want, cap)


func _option_slider(row: Container, limits: Vector2, step: float, value: float, key: StringName) -> HSlider:
	var s := HSlider.new()
	s.min_value = limits.x
	s.max_value = limits.y
	s.step = step
	s.custom_minimum_size = Vector2(110, 0)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE   # keys stay with the menu
	s.value = value
	s.value_changed.connect(func(v: float) -> void: set_option(key, v))
	row.add_child(s)
	var l := Label.new()
	l.custom_minimum_size = Vector2(48, 0)
	row.add_child(l)
	_option_values[key] = l
	return s


func _option_check(row: Container, text: String, tip: String, key: StringName, on: bool) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.tooltip_text = tip
	c.focus_mode = Control.FOCUS_NONE
	c.button_pressed = on
	c.toggled.connect(func(v: bool) -> void: set_option(key, v))
	row.add_child(c)
	return c


## G7: sets one of the options (a HudSettings field), saves it, shows it; main applies it on hud_changed.
func set_option(key: StringName, v: Variant) -> void:
	if not key in [&"look_speed", &"invert_y", &"fov", &"render_scale", &"ui_scale", &"fullscreen", &"vsync",
			&"weather_quality", &"volume", &"ambience_volume", &"main_hand", &"context_menu"]:
		return
	if key == &"main_hand" and not (v is String and v in HudSettings.MAIN_HANDS):
		return
	if key == &"context_menu" and not (v is int and v >= HudSettings.MENU_HOLD and v <= HudSettings.MENU_LIST):
		return
	hud.set(key, v)
	_show_options()
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Option not saved: %s" % error_string(err)
	hud_changed.emit()


func _show_options() -> void:
	_option_values[&"look_speed"].text = "x%.2f" % hud.look_speed
	_option_values[&"fov"].text = "%d%s" % [roundi(hud.fov), char(0xb0)]
	_option_values[&"render_scale"].text = "%d %%" % roundi(hud.render_scale * 100.0)
	_option_values[&"ui_scale"].text = "%d %%" % roundi(hud.ui_scale * 100.0)
	_option_values[&"volume"].text = "%d %%" % roundi(hud.volume * 100.0)
	_option_values[&"ambience_volume"].text = "%d %%" % roundi(hud.ambience_volume * 100.0)


## Adds the Cheats page (in place of the key list while shown) and its button in the bottom bar.
func add_cheat_page(panel: CheatPanel) -> void:
	cheat_page = panel
	cheat_scroll = ScrollContainer.new()
	cheat_scroll.name = "CheatScroll"
	cheat_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cheat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cheat_scroll.visible = false
	_box.add_child(cheat_scroll)
	_box.move_child(cheat_scroll, _scroll.get_index() + 1)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cheat_scroll.add_child(panel)
	panel.visible = false
	_update_cheats_button()


func cheats_allowed() -> bool:
	return cheat_page != null and (cheats_forced or (hud != null and hud.debug_cheats))


func showing_cheats() -> bool:
	return cheat_page != null and cheat_page.visible


## Swaps the key list for the Cheats page (on) or back. The page only opens while cheats are allowed.
func show_cheats(on: bool) -> void:
	on = on and cheats_allowed()
	_capture = []
	refresh()
	_scroll.visible = not on
	_title.text = ("Cheats (testing).  F1 / Esc closes.  Pad: D-pad picks, left / right change, A presses, X keys, "
			+ "B / Start closes") if on else KEYS_TITLE
	if cheat_page != null:
		cheat_page.visible = on
		cheat_scroll.visible = on
		if on:
			cheat_page.refresh()
	if cheats_button != null:
		cheats_button.text = "Keys" if on else "Cheats"


func _update_cheats_button() -> void:
	cheats_button.visible = cheats_allowed()
	if not cheats_allowed() and showing_cheats():
		show_cheats(false)


func _on_debug_cheats(on: bool) -> void:
	hud.debug_cheats = on
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Debug setting not saved: %s" % error_string(err)
	_update_cheats_button()
	hud_changed.emit()


func _on_ride_hud(on: bool) -> void:
	hud.ride_hud = on
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Driving gauge setting not saved: %s" % error_string(err)
	hud_changed.emit()


func _on_key_help(on: bool) -> void:
	hud.key_help = on
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Key help setting not saved: %s" % error_string(err)
	hud_changed.emit()


func _on_weather_flash(on: bool) -> void:
	hud.weather_flash = on
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Bright flashes setting not saved: %s" % error_string(err)
	hud_changed.emit()


## A feed group's box: checked shows the group's messages in the feed (HudData.set_feed_hidden via main).
func _on_feed_group(on: bool, group: String) -> void:
	var hidden := PackedStringArray(hud.feed_hidden)
	if on:
		if hidden.has(group):
			hidden.remove_at(hidden.find(group))
	elif not hidden.has(group):
		hidden.append(group)
	hud.feed_hidden = HudSettings.feed_groups_from(hidden)
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Message filter not saved: %s" % error_string(err)
	hud_changed.emit()


## An eye tracking box (HudSettings.set_eye): saved; with the master switch off the others grey out (but GAZE_FREE).
func _on_eye(on: bool, id: String) -> void:
	if not hud.set_eye(id, on):
		return
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Eye tracking setting not saved: %s" % error_string(err)
	_show_eyes()
	hud_changed.emit()


func _clock_box(row: Control, text: String, on: bool, call: Callable, tip: String) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.tooltip_text = tip
	c.focus_mode = Control.FOCUS_NONE
	c.button_pressed = on
	c.toggled.connect(call)
	row.add_child(c)
	return c


func _on_real_time(on: bool) -> void:
	hud.real_time = on
	_save_clock()


func _on_auto_pause(on: bool) -> void:
	hud.auto_pause = on
	_save_clock()


func _save_clock() -> void:
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Time setting not saved: %s" % error_string(err)
	hud_changed.emit()


## The Time row as the settings are now (the real-time key flips it outside the menu).
func show_clock() -> void:
	if hud != null and real_time_check != null:
		real_time_check.set_pressed_no_signal(hud.real_time)
		auto_pause_check.set_pressed_no_signal(hud.auto_pause)


func _show_eyes() -> void:
	var master := hud.eye_switch("tracker")
	for id: String in eye_checks:
		(eye_checks[id] as CheckBox).disabled = not master and id != "tracker" and not id in HudSettings.GAZE_FREE


func _on_mood_cues(on: bool) -> void:
	hud.mood_cues = on
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Mood tint setting not saved: %s" % error_string(err)
	hud_changed.emit()


func _on_hurt_cues(on: bool) -> void:
	hud.hurt_cues = on
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Hurt tint setting not saved: %s" % error_string(err)
	hud_changed.emit()


func _on_compass_opacity(v: float) -> void:
	hud.compass_opacity = HudSettings.clamp_opacity(v)
	_show_compass_value()
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Compass opacity not saved: %s" % error_string(err)
	hud_changed.emit()


func _show_compass_value() -> void:
	_compass_value.text = "%d %%" % roundi(hud.compass_opacity * 100.0)


func open() -> void:
	visible = true
	_fit_settings()   # the window may have changed while it was shut
	if compass_slider != null:
		compass_slider.set_value_no_signal(hud.compass_opacity)
		_show_compass_value()
		look_slider.set_value_no_signal(hud.look_speed)
		invert_check.set_pressed_no_signal(hud.invert_y)
		main_pick.select(maxi(HudSettings.MAIN_HANDS.find(hud.main_hand), 0))
		menu_pick.select(clampi(hud.context_menu, 0, HudSettings.MENU_NAMES.size() - 1))
		fov_slider.set_value_no_signal(hud.fov)
		scale_slider.set_value_no_signal(hud.render_scale)
		ui_slider.set_value_no_signal(hud.ui_scale)
		weather_pick.select(clampi(hud.weather_quality, 0, WeatherView.QUALITY_NAMES.size() - 1))
		volume_slider.set_value_no_signal(hud.volume)
		ambience_slider.set_value_no_signal(hud.ambience_volume)
	if hints_check != null:
		hints_check.set_pressed_no_signal(hints.enabled)
		fullscreen_check.set_pressed_no_signal(hud.fullscreen)
		vsync_check.set_pressed_no_signal(hud.vsync)
		_show_options()
	if debug_check != null:
		debug_check.set_pressed_no_signal(hud.debug_cheats)
	if cheats_button != null:
		_update_cheats_button()
		show_cheats(false)
	_capture = []
	_axis_held.clear()
	_status.text = "Saved in %s" % ProjectSettings.globalize_path(save_path)
	refresh()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	_capture = []
	visible = false
	closed.emit()


func refresh() -> void:
	for a: StringName in _buttons:
		var keys := InputActions.slots(a)
		for s in SLOTS:
			var b: Button = _buttons[a][s]
			b.text = InputActions.event_label(keys[s]) if s < keys.size() else "-"
			if s == SLOTS - 1 and keys.size() > SLOTS:
				b.text += " +%d" % (keys.size() - SLOTS)
		var pads := InputActions.pad_slots(a)
		for s in PAD_SLOTS:
			var p: Button = _buttons[a][PAD_SLOT + s]
			p.text = InputActions.event_label(pads[s]) if s < pads.size() else "-"
			if s == PAD_SLOTS - 1 and pads.size() > PAD_SLOTS:
				p.text += " +%d" % (pads.size() - PAD_SLOTS)
	_show_cursor()


## Highlights the slot picked with the pad and scrolls it into view.
func _show_cursor() -> void:
	var picked: Button = null
	if cursor.x >= 0 and cursor.x < InputActions.ACTIONS.size():
		picked = (_buttons[InputActions.ACTIONS[cursor.x][0]] as Array)[cursor.y]
	for a: StringName in _buttons:
		for b: Button in _buttons[a]:
			b.modulate = PICKED if b == picked else Color.WHITE
	if picked != null and _scroll.is_inside_tree():
		_scroll.ensure_control_visible(picked)


## Moves the pad's pick by `step` (x = slot, y = row); the first move picks the first row's pad slot.
func move_cursor(step: Vector2i) -> void:
	if cursor.x < 0:
		cursor = Vector2i(0, PAD_SLOT)
	else:
		cursor = Vector2i(clampi(cursor.x + step.y, 0, InputActions.ACTIONS.size() - 1), clampi(cursor.y + step.x, 0, LAST_SLOT))
	_show_cursor()


## A pad event while nothing is being set: D-pad / left stick move the pick, A sets the picked slot, B / Back /
## Start close, X swaps the Keys and Cheats pages. On the Cheats page the D-pad / stick and A go to its controls
## (up / down pick, left / right change). Always used (nothing reaches the game).
func _pad_nav(event: InputEvent) -> bool:
	var step := Vector2i.ZERO
	var b := event as InputEventJoypadButton
	if b != null:
		if not b.pressed:
			return true
		match b.button_index:
			JOY_BUTTON_B, JOY_BUTTON_BACK, JOY_BUTTON_START:
				close()
				return true
			JOY_BUTTON_A:
				if showing_cheats():
					cheat_page.pad_press()
				elif cursor.x >= 0:
					start_capture(InputActions.ACTIONS[cursor.x][0], cursor.y)
				return true
			JOY_BUTTON_X:
				if cheats_allowed():
					show_cheats(not showing_cheats())
				return true
			JOY_BUTTON_DPAD_UP:
				step = Vector2i(0, -1)
			JOY_BUTTON_DPAD_DOWN:
				step = Vector2i(0, 1)
			JOY_BUTTON_DPAD_LEFT:
				step = Vector2i(-1, 0)
			JOY_BUTTON_DPAD_RIGHT:
				step = Vector2i(1, 0)
	var m := event as InputEventJoypadMotion
	if m != null and m.axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y]:
		var v := m.axis_value
		var sgn := 0 if not absf(v) >= InputActions.PAD_PUSH else (1 if v > 0.0 else -1)   # NaN: 0
		if _axis_held.get(m.axis, 0) != sgn:
			_axis_held[m.axis] = sgn
			step = Vector2i(sgn, 0) if m.axis == JOY_AXIS_LEFT_X else Vector2i(0, sgn)
	if step != Vector2i.ZERO and showing_cheats():
		if step.y != 0:
			cheat_page.pad_move(step.y)
		else:
			cheat_page.pad_adjust(step.x)
	elif step != Vector2i.ZERO:
		move_cursor(step)
	return true


func start_capture(action: StringName, slot: int) -> void:
	if showing_cheats():
		return
	_capture = [action, slot]
	_pending_mod = KEY_NONE
	for i in InputActions.ACTIONS.size():   # a clicked slot is the pad's pick too
		if InputActions.ACTIONS[i][0] == action:
			cursor = Vector2i(i, clampi(slot, 0, LAST_SLOT))
	refresh()
	(_buttons[action][slot] as Button).text = "press a key..." if slot < SLOTS else "press a pad button..."
	_status.text = "Press %s for \"%s\". Esc cancels, Backspace clears." % [
			"a key or mouse button" if slot < SLOTS else "a pad button or push a stick", InputActions.info(action)[2]]


func reset_all() -> void:
	InputActions.reset_all()
	_save("All keys back to the defaults.")


func _input(event: InputEvent) -> void:
	if visible and (event is InputEventKey or InputActions.is_pad(event) or event is InputEventAction
			or (not _capture.is_empty() and event is InputEventMouseButton)):
		if _typing(event):
			return   # a text field on the cheats page gets its keys
		take(event)
		get_viewport().set_input_as_handled()


## A key for a focused text field on the cheats page (the range's item and monster ids); Esc and F1 still close.
func _typing(event: InputEvent) -> bool:
	var k := event as InputEventKey
	if k == null or not _capture.is_empty() or cheat_page == null or not cheat_page.visible \
			or k.physical_keycode in [KEY_ESCAPE, InputActions.MENU_KEY]:
		return false
	var vp := get_viewport()
	var f: Control = vp.gui_get_focus_owner() if vp != null else null
	return f is LineEdit and cheat_page.is_ancestor_of(f)


## One input event while the menu is open (separate from _input so tests can feed it). True if it was used.
func take(event: InputEvent) -> bool:
	var k := event as InputEventKey
	if event is InputEventAction:   # the VR panel's B / Y: backs out of a capture, else closes; others pass
		if not event.is_pressed():
			return false
		var act := (event as InputEventAction).action
		if showing_cheats() and _capture.is_empty() and act in CHEAT_ACTIONS:   # the VR stick on the Cheats page
			var d: int = CHEAT_ACTIONS[act]
			if act == &"ui_accept":
				cheat_page.pad_press()
			elif act in [&"ui_up", &"ui_down"]:
				cheat_page.pad_move(d)
			else:
				cheat_page.pad_adjust(d)
			return true
		if act != &"ui_cancel":
			return false
		if _capture.is_empty():
			close()
		else:
			_capture = []
			refresh()
			_status.text = "Cancelled."
		return true
	if _capture.is_empty():
		if k != null and k.pressed and not k.echo and k.physical_keycode in [KEY_ESCAPE, InputActions.MENU_KEY]:
			close()
			return true
		if InputActions.is_pad(event):
			return _pad_nav(event)
		return false
	var pad: bool = _capture[1] >= SLOTS
	if InputActions.is_pad(event):   # pad presses only go in the pad column
		var pb := event as InputEventJoypadButton
		if pad and pb != null and pb.pressed and pb.button_index == InputActions.MENU_PAD:
			_status.text = "Start backs out and opens this menu, like Esc; it can't be bound."
			return true
		if pad:
			return _bind(InputActions.pad_binding_from(event))
		if pb != null and pb.pressed and pb.button_index in [JOY_BUTTON_B, JOY_BUTTON_BACK, JOY_BUTTON_START]:
			_capture = []   # a key slot picked with the pad: B / Back / Start back out without a keyboard
			refresh()
			_status.text = "Cancelled."
			return true
		return false
	if k != null and not k.pressed:
		if not pad and _pending_mod != KEY_NONE and k.physical_keycode == _pending_mod:
			return _bind(InputActions.binding_from(k))   # a modifier let go alone: bind it bare
		return false
	if k != null and k.echo:
		return false
	var mb := event as InputEventMouseButton
	if mb != null and not mb.pressed:
		return false
	if k != null:
		match k.physical_keycode:
			KEY_ESCAPE:
				_capture = []
				refresh()
				_status.text = "Cancelled."
				return true
			KEY_BACKSPACE, KEY_DELETE:
				return _set_slot(null)
			InputActions.MENU_KEY:
				_status.text = "F1 opens this menu and can't be bound."
				return true
			KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META:
				if not pad:
					_pending_mod = k.physical_keycode
					return true
	if pad:
		_status.text = "Press a pad button or push a stick or trigger. Esc cancels, Backspace clears."
		return true
	return _bind(InputActions.binding_from(event))


func _bind(e: InputEvent) -> bool:
	if e == null:
		return false
	return _set_slot(e)


## Puts `e` in the slot being captured (null clears it), saves, and names other actions on the same key.
func _set_slot(e: InputEvent) -> bool:
	var action: StringName = _capture[0]
	var slot: int = _capture[1]
	var pad := slot >= SLOTS
	if pad:
		slot -= SLOTS
	_capture = []
	_pending_mod = KEY_NONE
	var keys := InputActions.pad_slots(action) if pad else InputActions.slots(action)
	if e != null:
		for i in range(keys.size() - 1, -1, -1):   # the same key twice in one action: keep one
			if InputActions.event_text(keys[i]) == InputActions.event_text(e):
				keys.remove_at(i)
	if slot < keys.size():
		keys.remove_at(slot)
	if e != null:
		keys.insert(mini(slot, keys.size()), e)
	if pad:
		InputActions.set_pad_slots(action, keys)
	else:
		InputActions.set_slots(action, keys)
	var msg := "%s: %s" % [InputActions.info(action)[2], InputActions.event_label(e) if e != null else "cleared"]
	if e != null:
		var others := PackedStringArray()
		for o in InputActions.users_of(e, action):
			others.append(InputActions.info(o)[2])
		if not others.is_empty():
			msg += ". Also used by: " + ", ".join(others)
	_save(msg)
	return true


func _save(msg: String) -> void:
	var err := InputActions.save_bindings(save_path)
	refresh()
	_status.text = msg if err == "" else "%s. Not saved: %s" % [msg, err]
	_status.add_theme_color_override("font_color", WARN if err != "" or msg.contains("Also used") else Color.WHITE)
