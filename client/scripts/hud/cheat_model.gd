class_name CheatModel
extends RefCounted
## K7: the cheat page's rows without any UI, shared by the flat F1 page (ui/cheat_panel.gd) and the VR page (vr/),
## so both show the same toggles in the same order. `backend` is a LiveSession (or a stand-in with its methods:
## cheats(), auto_pause(), set_cheat(), set_auto_pause(), give_test_kit()). Nothing is kept here: rows are built
## from what the sim says each time (LiveSession.cheats() asks the bridge).

## One per LiveSession.CHEATS name, plus the two extra rows.
const LABELS := {
	"invincible": "No damage (can't die)",
	"no_needs": "No hunger, thirst or sleepiness",
	"no_weight_limit": "No weight limit",
	"unlimited_ammo": "Unlimited ammo (wielded gun)",
	"stamina": "Unlimited stamina",
	"no_temperature": "No heat or cold",
	"night_vision": "Night vision (also reveals the map)",
	AUTO_PAUSE: "Auto-pause on hostiles (real time)",
	TEST_KIT: "Give test kit",
}
const AUTO_PAUSE := "auto_pause"
const TEST_KIT := "test_kit"
const TOGGLE := "toggle"
const ACTION := "action"


## [{key, label, on, kind: "toggle" | "action", enabled}]: the cheats in LiveSession.CHEATS order, then the
## auto-pause toggle, then the test-kit action. `cheats` is LiveSession.cheats(): {} (no running game) greys every
## row out. Only real bools count as on.
static func rows(cheats: Dictionary, auto_pause: bool) -> Array[Dictionary]:
	var live := not cheats.is_empty()
	var out: Array[Dictionary] = []
	for n: String in LiveSession.CHEATS:
		var v: Variant = cheats.get(n, false)
		out.append({"key": n, "label": LABELS[n], "on": live and v is bool and v, "kind": TOGGLE, "enabled": live})
	out.append({"key": AUTO_PAUSE, "label": LABELS[AUTO_PAUSE], "on": live and auto_pause, "kind": TOGGLE,
			"enabled": live})
	out.append({"key": TEST_KIT, "label": LABELS[TEST_KIT], "on": false, "kind": ACTION, "enabled": live})
	return out


## The rows as the sim has them now (no backend: every row greyed out).
static func read(backend: Object) -> Array[Dictionary]:
	if backend == null or not is_instance_valid(backend):
		return rows({}, false)
	var c: Dictionary = backend.cheats()
	return rows(c, not c.is_empty() and backend.auto_pause())


## Does a row: a cheat or auto-pause set to `on`, the test kit given (one per call; `on` unused). False when the
## sim refused (no running game) or the key is unknown. A cheat change shows once the sim applies it
## (LiveSession.cheats_changed), so read() again then.
static func apply(backend: Object, key: String, on := true) -> bool:
	if backend == null or not is_instance_valid(backend):
		return false
	if key == TEST_KIT:
		return backend.give_test_kit()
	if key == AUTO_PAUSE:
		return backend.set_auto_pause(on)
	if key in LiveSession.CHEATS:
		return backend.set_cheat(key, on)
	return false
