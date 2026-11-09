extends SceneTree
## Adds Vive wand, Valve Index and WMR controller bindings to client/openxr_action_map.tres (Godot's default map
## only had Touch, Pico and the generic controller). Run once from the repo root; profiles already there stay:
##   Godot_v4.7.2-stable_win64_console.exe --headless --path client --script ../tools/vr/add_controller_profiles.gd

const MAP := "res://openxr_action_map.tres"
const POSES := {"default_pose": "input/aim/pose", "aim_pose": "input/aim/pose", "grip_pose": "input/grip/pose",
		"haptic": "output/haptic"}
## Profile -> {action: path for both hands, or [left path, right path] ("" = none)}.
const PROFILES := {
	"/interaction_profiles/htc/vive_controller": {
		"menu_button": "input/menu/click", "trigger": "input/trigger/value", "trigger_click": "input/trigger/click",
		"grip": "input/squeeze/click", "grip_click": "input/squeeze/click", "primary": "input/trackpad",
		"primary_click": "input/trackpad/click", "primary_touch": "input/trackpad/touch",
	},
	"/interaction_profiles/valve/index_controller": {
		# No menu button on Index (system is the runtime's): the left stick click opens our menu.
		"menu_button": ["input/thumbstick/click", ""], "primary_click": ["", "input/thumbstick/click"],
		"ax_button": "input/a/click", "ax_touch": "input/a/touch", "by_button": "input/b/click",
		"by_touch": "input/b/touch", "trigger": "input/trigger/value", "trigger_click": "input/trigger/click",
		"trigger_touch": "input/trigger/touch", "grip": "input/squeeze/value", "grip_click": "input/squeeze/value",
		"grip_force": "input/squeeze/force", "primary": "input/thumbstick", "primary_touch": "input/thumbstick/touch",
		"secondary": "input/trackpad", "secondary_click": "input/trackpad/force", "secondary_touch": "input/trackpad/touch",
	},
	"/interaction_profiles/microsoft/motion_controller": {
		"menu_button": "input/menu/click", "trigger": "input/trigger/value", "trigger_click": "input/trigger/value",
		"grip": "input/squeeze/click", "grip_click": "input/squeeze/click", "primary": "input/thumbstick",
		"primary_click": "input/thumbstick/click", "secondary": "input/trackpad",
		"secondary_click": "input/trackpad/click", "secondary_touch": "input/trackpad/touch",
	},
}


func _initialize() -> void:
	var am := load(MAP) as OpenXRActionMap
	var actions := {}
	for set: OpenXRActionSet in am.action_sets:
		for a: OpenXRAction in set.actions:
			actions[a.resource_name] = a
	for path: String in PROFILES:
		if am.find_interaction_profile(path) != null:
			print("have " + path)
			continue
		var prof := OpenXRInteractionProfile.new()
		prof.interaction_profile_path = path
		var binds := []
		var all: Dictionary = POSES.duplicate()
		all.merge(PROFILES[path])
		for act: String in all:
			var v: Variant = all[act]
			var per: Array = v if v is Array else [v, v]
			for i in 2:
				if per[i] == "":
					continue
				var b := OpenXRIPBinding.new()
				b.action = actions[act]
				b.binding_path = "/user/hand/%s/%s" % ["left" if i == 0 else "right", per[i]]
				binds.append(b)
		prof.bindings = binds
		am.add_interaction_profile(prof)
		print("added %s (%d bindings)" % [path, binds.size()])
	print("save: " + error_string(ResourceSaver.save(am, MAP)))
	quit()
