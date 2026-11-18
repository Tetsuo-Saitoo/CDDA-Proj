class_name VrGun
extends Node3D
## Block L2: guns handled by hand in VR (VrRig `gun`). While CDDA wields a gun (Snapshot.player_gun), its model
## (WeaponViewmodel.build) is in the main hand: its Grip marker at the controller's grip pose (the runtime's, else
## GRIP_FROM_AIM off the aim pose), the bore along the hand's pointing direction; VrHeld hides on that hand meanwhile.
## Grime, the magazine (the carried rows under the gun) and a jam change the model only when the snapshot changes.
## - Fire: the main trigger (before stairs and the pull) fires from the Muzzle pose (AimController.fire_from). With no
##   fire request showing, CDDA's own `fire` action goes out once and the shot follows when its request shows (within
##   FIRE_WAIT_S); a fire request the client can't fly is answered with plain FIRE at CDDA's cursor. `live_aim` gives
##   the muzzle pose for each projectile of a burst. A buzz per shot, a thump when it hits (HitFeedback.shot_confirmed),
##   a strong one for a kill; the model kicks (visual only). A trigger pull CDDA fired no round for
##   (HitFeedback.misfired): the kick stops and a light buzz; the click itself is WeaponViewmodel's (it stays in the
##   tree in VR). A round CDDA fired (AimController.shot_went) flashes at the Muzzle as on the flat screen
##   (WeaponViewmodel.build_flash: a star and a shadowless light for FLASH_S, at most once every FLASH_GAP_S, so under 3
##   a second); none with `flashes` off (the flash setting) or a suppressed gun. The flash is the model's child: it goes
##   with it.
## - Magazine out: the off grip within MAG_OUT_M of MagWell while a magazine is inside unloads it into CDDA's off hand
##   (ItemActions.unload "off"); its copy rides in the off hand meanwhile, then the hand holds the magazine
##   (Hands.adopt; the grip let go before that: let go like any held item). Refused: it snaps back, CDDA's reason by
##   the hand.
## - Magazine in: the off hand holding a magazine (or rounds) within MAG_IN_M of MagWell, its up within MAG_IN_DOT of
##   MagWell's +Y: ItemActions.reload(gun, it); the hand lets it go (nothing sent) and the gun shows it once the
##   snapshot does. Refused: back in the hand with CDDA's reason. The next try needs the hand away first (REARM_M).
## - Rack: the off grip within RACK_REACH_M of the Slide / Bolt, pulled back along the bore past RACK_PULL_M and let
##   go: a jammed gun queues CDDA's reload_weapon (the fork clears the jam), a clean one only racks and buzzes. A jam
##   showing up says what jammed by the main hand.
## - Mods: the gunmods CDDA lists as installed (player_gun `mods`) show as GunMods boxes at their slots, made again only
##   when the list (or the model) changes.
## - Fitting a mod (gun modification by hand, S2): a gunmod (its id table `gunmod_location`) in the off hand within
##   GLOW_M of the slot its location takes on this gun lights a ghost there, green when CDDA says it fits (player_gun
##   `fits`), red when not; the odds or CDDA's reason by the hand. Let go within FIT_M: one that fits goes to CDDA's
##   mod_add (ItemActions.mod_add, tagged), the hand lets go and the ghost stays white until CDDA answers; refused
##   (or "Never mind." to its question): back in the hand with the reason. One that doesn't fit is let go as usual.
##   A bridge without `fits` (older): no ghost.
## - Taking a mod off (S3): the off grip within MOD_REACH_M of an installed mod's box (nearer than the slide / bolt and
##   the well) holds it; the box follows the hand out (MOD_TRAVEL at most); pulled MOD_PULL_M from where it was
##   gripped, CDDA's mod_remove goes out (ItemActions.mod_remove, tagged) and the box stays out until CDDA answers;
##   let go sooner: it snaps back. Refused: it snaps back, the reason by the hand. CDDA puts the mod in the pack (else
##   on the ground); it lands in the hand that pulled it if that grip is still down when it shows carried. A mod CDDA
##   can't take off (`mods` flag 1) says so.
## - A bench vise (V1, Vise): the main grip let go within VISE_M of the jaws of a `bench_vise` lying in reach leaves the
##   gun there (`vise`; CDDA still wields it, only shown so): the main hand is free (VrRig._gun_hand false) and fits or
##   pulls off mods and racks like the off hand (the magazine stays the off hand's); the trigger doesn't fire, no live
##   aim. The main grip on the gun's Grip takes it back; the head more than VISE_LEAVE_M away, or the vise taken or
##   gone: back in the hand (UNCLAMPED).
## The sim decides every outcome. Snapshot data is checked and capped here; per frame only a pose and a few distances.

const SHAPES: Array[String] = ["pistol", "long", "launcher"]   # WeaponViewmodel shapes with the named parts
const DEFAULT_SHAPE := "pistol"   # any other shape the id tables give a wielded gun
## The grip pose in the aim pose's space when the runtime gives none: behind and under the aim point, turned the same.
const GRIP_FROM_AIM := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.03, 0.08))
const MAG_OUT_M := 0.06       # the off grip this near MagWell takes the magazine out
const MAG_IN_M := 0.05        # a held magazine this near MagWell ...
const MAG_IN_DOT := 0.7       # ... and turned this close to its +Y goes in
const REARM_M := 0.1          # after a try (or a magazine out) the hand must be this far from MagWell first
const RACK_REACH_M := 0.05    # the off grip this near the Slide / Bolt holds it
const RACK_PULL_M := 0.04     # pulled back this far, then let go: racked
const RACK_TRAVEL := 0.05     # the slide / bolt follows the hand back this far at most
const FIRE_WAIT_S := 3.0      # after queueing `fire`, its request is fired at if it shows within this
const KICK_BACK := 0.03       # m, the model's recoil (visual only)
const KICK_ROT := 0.12        # radians, muzzle up
const KICK_RATE := 8.0        # 1/s back to rest
const SHOT_AMP := 0.6
const SHOT_S := 0.05
const KILL_AMP := 1.0
const KILL_S := 0.15
const HIT_AMP := 0.4         # a shot of the player's that hit (HitFeedback.shot_confirmed) ...
const HIT_S := 0.08          # ... a softer, longer thump than the shot's
const CLICK_AMP := 0.25       # a misfire's dry click
const CLICK_S := 0.02
const MAX_FAULTS := 16        # faults looked at (Snapshot's cap)
const MAX_ROUNDS := 100000
const LOAD_CATEGORIES := ["magazines", "ammo"]   # what the off hand puts into the well
const RACK_PARTS := ["Slide", "Bolt"]
const PARTS := ["Muzzle", "Grip", "MagWell", "Magazine", "Slide", "Bolt"]
const CANT_CLEAR := "Not now: the game is busy."
const CLEARING := "Clearing it..."
const CLEAR_WAIT_S := 20.0    # after a rack asked to clear a jam, no other rack asks again until it's gone (or this)
const COUNT_OFF := Vector3(0.0, 0.075, 0.02)   # the round count: this far over the Grip marker (model space)
const COUNT_PX := 0.00025     # ... its letters (about 8 mm digits)
const EMPTY_COLOR := Color(1.0, 0.35, 0.3)     # ... at 0
const GLOW_M := 0.2           # a gunmod in the off hand this near its slot lights it (the ghost)
const FIT_M := 0.06           # ... this near, let go: CDDA fits it
const HINT_S := 2.0           # its line by the hand is said again this often while it stays near
const GHOST_GROW := 1.1       # the ghost is this much bigger than the mod's box
const GHOST_OK := Color(0.35, 1.0, 0.45, 0.45)
const GHOST_NO := Color(1.0, 0.35, 0.3, 0.45)
const GHOST_BUSY := Color(1.0, 1.0, 1.0, 0.3)
const FITS := "Let go to fit it"
const MOD_REACH_M := 0.04     # the off grip this near an installed mod's box holds it
const MOD_PULL_M := 0.05      # ... pulled this far from where it was gripped: CDDA takes it off
const MOD_TRAVEL := 0.03      # ... its box follows the hand this far at most
const STUCK := "The %s can't be taken off."
const VISE_M := 0.15          # the main grip let go this near a bench vise's jaws: the gun stays in the vise
const VISE_LEAVE_M := 2.0     # the head farther than this from the gun in a vise: back in the hand
const TAKE_M := 0.1           # the main grip this near the Grip of the gun in a vise takes it back
const UNCLAMPED := "You take your gun out of the vise."
const NO_FIT := "That doesn't fit this gun."

var rig: VrRig
## (action: String) -> bool: queues one of CDDA's main-loop actions (main.gd: LiveSession, only in the main loop).
var queue_action := Callable()
## Fires and hit confirmations (main.gd's AimController); the gun gives it `live_aim`.
var aim: AimController:
	set(a):
		if is_instance_valid(aim):
			if aim.fired.is_connected(_on_fired):
				aim.fired.disconnect(_on_fired)
			if aim.shot_went.is_connected(_on_shot_went):
				aim.shot_went.disconnect(_on_shot_went)
			if aim.hits != null and aim.hits.shot_confirmed.is_connected(_on_hit):
				aim.hits.shot_confirmed.disconnect(_on_hit)
			if aim.hits != null and aim.hits.misfired.is_connected(_on_misfired):
				aim.hits.misfired.disconnect(_on_misfired)
			if aim.live_aim == Callable(live_pose):
				aim.live_aim = Callable()
		aim = a
		if a != null:
			a.fired.connect(_on_fired)
			a.shot_went.connect(_on_shot_went)
			if a.hits != null:
				a.hits.shot_confirmed.connect(_on_hit)
				a.hits.misfired.connect(_on_misfired)
			a.live_aim = live_pose
## The one-item unload / reload (main.gd's ItemActions).
var actions: ItemActions:
	set(a):
		if is_instance_valid(actions):
			if actions.finished.is_connected(_on_finished):
				actions.finished.disconnect(_on_finished)
			if actions.refused.is_connected(_on_refused):
				actions.refused.disconnect(_on_refused)
		actions = a
		if a != null:
			a.finished.connect(_on_finished)
			a.refused.connect(_on_refused)

var model: Node3D             # WeaponViewmodel.build's model, null without a gun
var shape := ""
var gun_type := 0             # itype index of the wielded gun, 0 none
var gun: ItemRef              # its carried row (null: not listed)
var mag: ItemRef              # the magazine in it (carried row), null none
var rounds_in: ItemRef        # rounds loaded straight into it, null none
var rounds := -1              # player_gun.rounds (-1 absent): used only when the gun's row isn't listed
var dirt := -1
var grime := 0.0
var jam := ""                 # WeaponViewmodel.JAMS id, "" none
var shown := false            # the model shows in the main hand
var flashes := true           # muzzle flashes at all (main.gd: the flash setting); off: shots only kick
var suppressed := false       # the wielded gun has a suppressor (Snapshot.player_gun): no flash
var flashed := 0              # muzzle flashes shown (tests)
var count: Label3D            # the loaded rounds (player_gun.rounds) over the grip; hidden for a gun that takes none
var mods: Array[Dictionary] = []   # the installed gunmods shown (GunMods.mods_of player_gun)
## The gunmod the off hand holds near its slot (or the one being fitted): {uid, item, location, at, size (model space),
## ok, text, near (within FIT_M)}; {} none.
var fit := {}
var ghost: MeshInstance3D     # where it goes: a see-through box at its slot (green fits, red doesn't, white in flight)
var _hint := ""               # the line last said by the off hand for `fit`
var _pull := {}               # an installed mod the off grip holds: {uid, type, hand, start (model space), box, rest}
var _take_mod := {}           # a mod CDDA took off: {uid, hand}: into that hand once carried, if its grip is still down
var vise := {}                # the bench vise the gun is held in: {uid, pose (the gun's, world)}; {}: in the hand
var _vises: Array[int] = []   # the bench vises in reach (Vise.near), per snapshot
var _hinted := {}             # VR hint ids asked for this run (VrRig.hint_due; Hints shows each once, ever)
var _hint_left := 0.0
var fire_wait := 0.0          # > 0: CDDA's `fire` went out, seconds left to fire at its request
var kicks := 0                # shots kicked (tests)
var misfires := 0             # misfire clicks felt (tests)
var hits := 0                 # shot hits felt (tests)
var racks := 0                # full racks (tests)
var _snap: Snapshot           # the snapshot last looked at, and its seq
var _seq := -1
var _hold := Transform3D.IDENTITY   # where the model is held this frame (world, no kick)
var _local := {}              # part -> Transform3D in the model holder's (this node's) space
var _half := {}               # part -> half size of its box
var _rest := {}               # Slide / Bolt -> its rest position
var _grime_mats: Array[ShaderMaterial] = []
var _kick := 0.0
var _flash: Node3D            # WeaponViewmodel.build_flash under the model's Muzzle, null without one
var _flash_t := 0.0           # seconds the flash still shows
var _flash_wait := 0.0        # seconds before the next flash may show
var _op := {}                 # the gun's item action in flight: {op, uid (the gun), mag (unload), item (reload)}
var _copy: MeshInstance3D     # the magazine riding in the off hand while it comes out
var _rack := {}               # {part, hand (0 left / 1 right), start (z along the bore), max (pulled)}
var _rearm := true
var _clearing := ""           # the jam a rack already asked CDDA to clear ("" none)
var _clear_left := 0.0        # seconds before another rack may ask again


func _init() -> void:
	name = "VrGun"
	top_level = true   # placed in world space every frame
	visible = false


## Per frame (VrRig._process, after update_hands): follows the snapshot when it changed, holds the model in the main
## hand, fires at a queued fire's request, moves a rack, and looks for a magazine brought to the well.
func update(delta: float) -> void:
	if rig == null:
		return
	var d := clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	_tick_flash(d)
	var s := rig.world.snapshot
	if s != _snap or (s != null and s.seq != _seq):
		_refresh(s)
	if clamped() and (not Vise.jaws(rig.hands.picker if rig.hands != null else null, int(vise["uid"])) is Vector3 \
			or rig.camera.global_position.distance_to((vise["pose"] as Transform3D).origin) > VISE_LEAVE_M):
		_unclamp(UNCLAMPED)   # walked off, or the vise was picked up or is gone
	var on := model != null and is_inside_tree() \
			and (clamped() or rig.hands == null or rig.hands.proxy(rig.hand_id(rig.main_ctrl())) == null)
	if on != shown:
		shown = on
		visible = on
		if not on:
			_rack = {}
			_pull = {}
			fire_wait = 0.0
			fit = {}
			_show_ghost()
			_pose_parts()
		else:
			_ask_hint("vr_gun")
			if _local.has("MagWell"):
				_ask_hint("vr_mag")
			if not mods.is_empty():
				_ask_hint("vr_mod_off")
		rig.sync_held()
	if not on:
		return
	_kick = move_toward(_kick, 0.0, KICK_RATE * d)
	_clear_left = maxf(_clear_left - d, 0.0)
	_place()
	if _copy != null:
		_copy.transform = rig.off_ctrl().global_transform
	if fire_wait > 0.0:
		_tick_fire(d)
	if not _pull.is_empty():
		_tick_pull()
	if not _rack.is_empty():
		_tick_rack()
	elif not rig.menu_open():
		_try_insert()
	_hover_mod(d)


## The main trigger (VrRig.press, after the pack): true when the gun took it (it shows). Fires from the muzzle;
## nothing to fire at yet: queues CDDA's `fire` once.
func trigger() -> bool:
	if not shown or rig == null or clamped():
		return false
	var c := rig.main_ctrl()
	if aim == null:
		rig.feel(c)
		return true
	_update_hold()
	var pose := live_pose()
	if not pose.is_empty() and aim.fire_from(pose["origin"], pose["sight"]):
		fire_wait = 0.0
		return true   # `fired`: the kick and the buzz
	var t := _fire_request()
	if t != null:
		fire_wait = 0.0
		if not _fire_plain(t):
			rig.feel(c)   # the muzzle points at nothing to shoot (or at your own square): no shot
		return true
	if aim.request_ui != null and aim.request_ui.target_widget() != null:
		rig.feel(c)   # aiming something else (a throw...): not the gun's
		return true
	if fire_wait > 0.0:
		return true   # CDDA's fire is on its way: sent once
	var ok: Variant = queue_action.call("fire") if queue_action.is_valid() else false
	if ok is bool and ok:
		fire_wait = FIRE_WAIT_S
	else:
		rig.feel(c)   # the game can't take it now
	return true


## The off hand's grip (VrRig.press, before grabbing): on the Slide / Bolt it starts a rack, at MagWell with a
## magazine inside it takes the magazine out. True when the gun took it.
func grip(c: XRController3D) -> bool:
	if not shown or rig == null or (c == rig.main_ctrl() and not clamped()) or rig.hands == null or rig.menu_open():
		return false
	var i := _index(c)
	if not rig.hands.holding(rig.hand_id(c)).is_empty() or rig.pack.hand == i:
		return false
	_update_hold()
	var p := c.global_position
	if c == rig.main_ctrl() and p.distance_to(part_pose("Grip").origin) <= TAKE_M:
		_unclamp()   # the main hand takes the gun out of the vise
		return true
	var rack_part := ""
	var rack_d := INF
	for part: String in RACK_PARTS:
		var dd := _box_dist(part, p)
		if dd < rack_d:
			rack_d = dd
			rack_part = part
	var well_d := p.distance_to(part_pose("MagWell").origin) if _local.has("MagWell") else INF
	var can_out := c == rig.off_ctrl() and mag != null and gun != null and actions != null and _op.is_empty() \
			and well_d <= MAG_OUT_M
	var mod_hit := _mod_at(p)
	var mod_d: float = mod_hit[1]
	if mod_d <= MOD_REACH_M and mod_d < rack_d and (not can_out or mod_d < well_d):
		return _grip_mod(c, int(mod_hit[0]))
	if rack_d <= RACK_REACH_M and (not can_out or rack_d <= well_d):
		_rack = {"part": rack_part, "hand": i, "start": (_hold.affine_inverse() * p).z, "max": 0.0}
		return true
	if can_out:
		_unload(c)
		return true
	return false


## The grip let go (VrRig.release, first): ends that hand's rack, or puts back the mod it held before it came off.
## True when it did.
func release(c: XRController3D) -> bool:
	if not _pull.is_empty() and rig != null and _pull.get("hand") == _index(c):
		var bx: Variant = _pull.get("box")
		if is_instance_valid(bx):
			(bx as Node3D).position = _pull["rest"]
		_pull = {}
		return true
	if _rack.is_empty() or rig == null or _rack.get("hand") != _index(c):
		return false
	var pulled: float = _rack["max"]
	_rack = {}
	_pose_parts()
	if pulled < RACK_PULL_M:
		return true   # not pulled far enough: nothing
	racks += 1
	if jam != "" and _clearing == jam and _clear_left > 0.0:
		rig.say(_index(c), CLEARING)   # one clear per jam: another would reload the cleared gun
	elif jam != "":
		if _ask_clear():
			_clearing = jam
			_clear_left = CLEAR_WAIT_S
		else:
			rig.say(_index(c), CANT_CLEAR)
	rig.feel(c)
	return true


## Asks for VR hint `id` once this run (VrRig.hint_due; Hints decides whether it shows).
func _ask_hint(id: String) -> void:
	if rig != null and not _hinted.has(id):
		_hinted[id] = true
		rig.hint_due.emit(id)


## The gun is held in a bench vise (`vise`), not by the main hand.
func clamped() -> bool:
	return not vise.is_empty()


## The main grip let go with the gun in it (VrRig.let_go, before the body slots): within VISE_M of the jaws of a bench
## vise in reach, the gun stays where it is, held by the vise (only shown so: CDDA still wields it); the main hand is
## free. True when it did.
func let_go_gun(c: XRController3D) -> bool:
	if not shown or rig == null or rig.hands == null or c != rig.main_ctrl() or clamped():
		return false
	var best := -1
	var best_d := VISE_M
	for uid: int in _vises:
		var j: Variant = Vise.jaws(rig.hands.picker, uid)
		if j is Vector3 and c.global_position.distance_to(j) <= best_d:
			best = uid
			best_d = c.global_position.distance_to(j)
	if best < 0:
		return false
	_update_hold()
	vise = {"uid": best, "pose": _hold}
	_kick = 0.0
	fire_wait = 0.0
	rig.feel(c)
	rig.sync_held()
	return true


## The gun out of the vise, back in the main hand (`why` said by it); a pull or rack that hand had ends.
func _unclamp(why := "") -> void:
	if vise.is_empty():
		return
	vise = {}
	if rig == null:
		return
	var c := rig.main_ctrl()
	if _pull.get("hand") == _index(c):
		var bx: Variant = _pull.get("box")
		if is_instance_valid(bx):
			(bx as Node3D).position = _pull["rest"]
		_pull = {}
	if _rack.get("hand") == _index(c):
		_rack = {}
		_pose_parts()
	rig.feel(c)
	if not why.is_empty():
		rig.say(_index(c), why)
	rig.sync_held()


## A free hand let go of `it` (VrRig.let_go, first; the off hand, either in a vise): a gunmod within FIT_M of its slot that CDDA says fits (or doesn't
## judge) goes to CDDA's mod_add; the hand lets go, nothing dropped, the ghost stays white until CDDA answers. True
## when it took it; false (let go as usual) for anything else, a mod that doesn't fit too (its reason is by the hand).
func let_go_mod(c: XRController3D, it: ItemRef) -> bool:
	if not shown or rig == null or rig.hands == null or (c != rig.off_ctrl() and not clamped()) or it == null \
			or gun == null or actions == null or not _op.is_empty():
		return false
	var f := _mod_near(c)
	if f.is_empty() or not f["near"] or not f["ok"] or f["uid"] != it.uid:
		return false
	rig.hands.release(rig.hand_id(c), {})   # the hand lets go, nothing sent: CDDA has the mod until it is fitted
	var o := {"op": "mod_add", "uid": it.uid, "item": it, "fit": f, "hand": _index(c)}
	_op = o
	_hint = ""
	if actions.mod_add(it, gun):
		return true   # (a backend that answers inside the call has had _on_finished / _on_refused run already)
	if is_same(_op, o):
		_op = {}
	_readopt(it, _index(c))
	rig.feel(c)
	rig.say(_index(c), CANT_CLEAR)
	return true


## The installed mod whose box is nearest world point p: [index in `mods`, distance (m) to its box]; [-1, INF] none.
func _mod_at(p: Vector3) -> Array:
	var h := model.get_node_or_null(GunMods.HOLDER) as Node3D if model != null else null
	var best := [-1, INF]
	if h == null:
		return best
	for i in mini(h.get_child_count(), mods.size()):
		var b := h.get_child(i) as MeshInstance3D
		if b == null or not b.mesh is BoxMesh:
			continue
		var l := b.global_transform.affine_inverse() * p
		var half := (b.mesh as BoxMesh).size * 0.5
		var d := (l - l.clamp(-half, half)).length()
		if is_finite(d) and d < float(best[1]):
			best = [i, d]
	return best


## The off grip on installed mod i: one CDDA can't take off (or a gun busy with another action) says so with a buzz;
## else it is held to be pulled off (_pull). True: the grip is the gun's.
func _grip_mod(c: XRController3D, i: int) -> bool:
	var m: Dictionary = mods[i]
	if (int(m["flags"]) & 1) != 0:
		rig.feel(c)
		rig.say(_index(c), STUCK % _type_name(int(m["type"])))
		return true
	var h := model.get_node_or_null(GunMods.HOLDER)
	var box := h.get_child(i) as Node3D if h != null and i < h.get_child_count() else null
	if box == null or actions == null or gun == null or not _op.is_empty():
		rig.feel(c)
		rig.say(_index(c), CANT_CLEAR)
		return true
	_pull = {"uid": m["uid"], "type": m["type"], "hand": _index(c), "box": box, "rest": box.position,
			"start": model.global_transform.affine_inverse() * c.global_position}
	return true


## The held mod's box follows the hand out (MOD_TRAVEL at most); pulled MOD_PULL_M from where it was gripped:
## CDDA's mod_remove goes out, the box stays out until CDDA answers.
func _tick_pull() -> void:
	var c := rig.left if int(_pull["hand"]) == 0 else rig.right
	var bx: Variant = _pull.get("box")
	if not is_instance_valid(bx) or model == null:
		_pull = {}   # the boxes were made again (the snapshot changed the mods)
		return
	var box: Node3D = bx
	var off := model.global_transform.affine_inverse() * c.global_position - (_pull["start"] as Vector3)
	if not off.is_finite():
		return
	box.position = (_pull["rest"] as Vector3) + off.limit_length(MOD_TRAVEL)
	if off.length() < MOD_PULL_M:
		return
	var o := {"op": "mod_remove", "uid": _pull["uid"], "type": _pull["type"], "hand": _pull["hand"], "box": box,
			"rest": _pull["rest"]}
	_pull = {}
	_op = o
	_take_mod = {}   # an older one is given up
	rig.feel(c)
	if actions.mod_remove(int(o["uid"]), int(o["type"]), gun):
		return   # (a backend that answers inside the call has had _on_finished / _on_refused run already)
	if is_same(_op, o):
		_op = {}
	box.position = o["rest"]
	rig.say(_index(c), CANT_CLEAR)


## The itype of installed mod `uid` (0 when it isn't listed).
func _type_of(uid: int) -> int:
	for m: Dictionary in mods:
		if m["uid"] == uid:
			return m["type"]
	return 0


## A mod CDDA took off: into the hand that pulled it once the snapshot shows it carried, if that grip is still down
## and the hand empty; else it stays where CDDA put it (the pack, or the ground: then it never shows carried).
func _take_off(s: Snapshot) -> void:
	var uid: int = _take_mod["uid"]
	var it := _carried_ref(s, uid)
	if it == null:
		if _type_of(uid) == 0:
			_take_mod = {}   # off the gun and not carried: on the ground
		return
	var c := rig.left if int(_take_mod["hand"]) == 0 else rig.right
	_take_mod = {}
	var id := rig.hand_id(c)
	if rig.hands == null or not rig.hands.holding(id).is_empty() or not rig.grip_down(c):
		return
	rig.hands.set_hand_pose(id, c.global_transform, true)
	rig.hands.adopt(id, it)


func _type_name(t: int) -> String:
	var def: IdTables.Def = rig.world.tables.def_at("itype", t) if rig.world.tables != null else null
	var n := InventoryModel.clean(def.name) if def != null else ""
	return n if not n.is_empty() else "mod"


## CDDA's judgement of carried gunmod `uid` against this gun (player_gun `fits`): {uid, ok, chance, risk, reason}; {}
## when it isn't listed.
func fit_of(uid: int) -> Dictionary:
	var fs: Variant = _snap.player_gun.get("fits") if _snap != null else null
	if not fs is Array:
		return {}
	for f: Variant in (fs as Array).slice(0, Snapshot.MAX_GUN_FITS):
		if f is Dictionary and (f as Dictionary).get("uid") == uid and (f as Dictionary).get("ok") is bool:
			return f
	return {}


## The gunmod hand c holds and the slot its location takes on this gun, when the hand is within GLOW_M of it: see
## `fit`. {} when it holds no gunmod (or one in flight), the bridge sends no `fits`, or the hand is farther.
func _mod_near(c: XRController3D) -> Dictionary:
	if model == null or rig.hands == null or rig.world.tables == null or _snap == null \
			or not _snap.player_gun.has("fits"):
		return {}
	var it: ItemRef = rig.hands.holding(rig.hand_id(c)).get("item")
	if it == null or not it.carried or (actions != null and actions.pending(it.uid) != ""):
		return {}
	var def := rig.world.tables.def_at("itype", it.type)
	var loc := def.gunmod_location if def != null else ""
	if loc.is_empty():
		return {}
	var k := 0
	for m: Dictionary in mods:
		if m["location"] == loc:
			k += 1
	var s := GunMods.slot(shape, loc, k)
	if s.is_empty():
		return {}
	var at: Vector3 = s["at"]
	var dist := c.global_position.distance_to(model.global_transform * at)
	if not (dist <= GLOW_M):
		return {}
	var f := fit_of(it.uid)
	var ok: bool = f.is_empty() or f["ok"] == true   # not listed: CDDA decides when it is let go
	var text := FITS
	var chance: int = f.get("chance", 100)
	if not ok:
		var why: String = f.get("reason", "")
		text = "Your %s %s" % [_gun_name(), why] if not why.is_empty() else NO_FIT
	elif chance < 100:
		text = "%s: %d%% (%d%% risk of damage)" % [FITS, chance, int(f.get("risk", 0))]
	return {"uid": it.uid, "item": it, "location": loc, "at": at, "size": s["size"], "ok": ok, "text": text,
			"near": dist <= FIT_M}


## Per frame: `fit` for the off hand (the one in flight while CDDA fits it), its ghost, and its line by the hand when
## it changes (again every HINT_S while it stays).
func _hover_mod(d: float) -> void:
	var busy: bool = _op.get("op") == "mod_add"
	var hc := rig.off_ctrl()
	var f := {}
	if not busy and not rig.menu_open() and _rack.is_empty():
		f = _mod_near(hc)
		if f.is_empty() and clamped():
			hc = rig.main_ctrl()   # in a vise either hand fits mods
			f = _mod_near(hc)
	if busy:
		f = _op.get("fit", {})
		hc = rig.left if int(_op.get("hand", _index(hc))) == 0 else rig.right
	elif not f.is_empty():
		_ask_hint("vr_mods")
	fit = f
	_show_ghost()
	if f.is_empty() or busy:
		_hint = ""
		return
	_hint_left -= d
	var text: String = f["text"]
	if text != _hint or _hint_left <= 0.0:
		_hint = text
		_hint_left = HINT_S
		rig.say(_index(hc), text)


## The ghost at `fit`'s slot (made once per model, under it), hidden without one.
func _show_ghost() -> void:
	if fit.is_empty() or model == null:
		if ghost != null and is_instance_valid(ghost):
			ghost.visible = false
		return
	if ghost == null or not is_instance_valid(ghost) or ghost.get_parent() != model:
		ghost = MeshInstance3D.new()
		ghost.name = "ModGhost"
		ghost.mesh = BoxMesh.new()
		var m := StandardMaterial3D.new()
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		ghost.material_override = m
		ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		model.add_child(ghost)
	var box := ghost.mesh as BoxMesh
	var size: Vector3 = (fit["size"] as Vector3) * GHOST_GROW
	if box.size != size:
		box.size = size
	ghost.position = fit["at"]
	var col := GHOST_BUSY if _op.get("op") == "mod_add" else (GHOST_OK if fit["ok"] else GHOST_NO)
	(ghost.material_override as StandardMaterial3D).albedo_color = col
	ghost.visible = true


func _gun_name() -> String:
	var def: IdTables.Def = rig.world.tables.def_at("itype", gun_type) if rig.world.tables != null else null
	var n := InventoryModel.clean(def.name) if def != null else ""
	return n if not n.is_empty() else "gun"


## Asks CDDA to clear the jam: ItemActions.clear_jam (the bridge's "clear" op, refused with a reason when the gun isn't
## jammed or can't be fixed) once lead-ui's wrapper exists, else CDDA's reload_weapon on the jammed gun (the fork mends
## the jam; one it can't mend gets a plain reload instead: only the clear op avoids that).
func _ask_clear() -> bool:
	if actions != null and gun != null and actions.has_method(&"clear_jam"):
		var r: Variant = actions.call(&"clear_jam", gun)
		return r is bool and r
	var ok: Variant = queue_action.call("reload_weapon") if queue_action.is_valid() else false
	return ok is bool and ok


## A rack is in progress (the off hand holds the slide / bolt).
func racking() -> bool:
	return not _rack.is_empty()


## The hand racking the slide or bolt now (0 left / 1 right), -1 none.
func rack_hand() -> int:
	var h: Variant = _rack.get("hand")
	return h if h is int else -1


## AimController.live_aim: the muzzle now ({origin, sight}) while the gun shows, else {}.
func live_pose() -> Dictionary:
	if not shown or clamped() or not _local.has("Muzzle"):
		return {}
	var m := part_pose("Muzzle")
	var sight := -m.basis.z
	if not m.origin.is_finite() or not sight.is_finite() or sight.length_squared() < 1e-12:
		return {}
	return {"origin": m.origin, "sight": sight.normalized()}


## A part's pose (world, without the kick): Muzzle, Grip, MagWell, Magazine, Slide, Bolt; its origin is INF when the
## model has no such part.
func part_pose(part: String) -> Transform3D:
	var l: Variant = _local.get(part)
	if not l is Transform3D:
		return Transform3D(Basis.IDENTITY, Vector3.INF)
	return _hold * (l as Transform3D)


## Something is in the gun: a magazine or rounds under it in the carried rows, or (its row not listed) rounds > 0.
func loaded() -> bool:
	if gun != null:
		return mag != null or rounds_in != null
	return rounds > 0


## The magazine's copy riding in the off hand while it comes out, null none (tests).
func mag_copy() -> MeshInstance3D:
	return _copy


## Controller c's grip pose (world): the runtime's when it tracks one, else GRIP_FROM_AIM off its aim pose.
func grip_pose(c: XRController3D) -> Transform3D:
	var t := XRServer.get_tracker(c.tracker) as XRPositionalTracker
	if t != null:
		var p := t.get_pose(&"grip")
		if p != null and p.has_tracking_data:
			var xf := rig.global_transform * p.get_adjusted_transform()
			if xf.is_finite():
				return xf
	return c.global_transform * GRIP_FROM_AIM


## Where a gun model is held: its grip point (`grip_at`, model space) at `grip`'s origin, the model turned like `grip`
## (the bore along its -Z, the hand's pointing direction).
static func hold_pose(grip: Transform3D, grip_at: Vector3) -> Transform3D:
	var b := grip.basis.orthonormalized()
	return Transform3D(b, grip.origin - b * grip_at)


## An item that goes into a gun's well by hand: a magazine or rounds (its id table category).
static func loadable(it: ItemRef, tables: IdTables) -> bool:
	var d: IdTables.Def = it.def(tables) if it != null and tables != null else null
	return d != null and d.category in LOAD_CATEGORIES


## The note by the main hand for a jam: what jammed and how to clear it by hand.
func jam_note(id: String) -> String:
	var what: String = WeaponViewmodel.JAMS.get(id, "Jammed")
	for part: String in RACK_PARTS:
		if _rest.has(part):
			return "%s: rack the %s to clear" % [what, part.to_lower()]
	return what


# --- inside ---

## The snapshot changed: which gun, its grime, what is in it and a jam. Rebuilds the model only for a new shape.
func _refresh(s: Snapshot) -> void:
	_snap = s
	_seq = s.seq if s != null else -1
	var g: Dictionary = s.player_gun if s != null else {}
	var t := _int_of(g.get("type"), 1, Snapshot.MAX_ID, 0)   # a missing or bad type: no gun
	if t <= 0:
		_clear()
		return
	var tables := rig.world.tables
	var def: IdTables.Def = tables.def_at("itype", t) if tables != null else null
	var sh := WeaponViewmodel.shape_for(def)
	if not sh in SHAPES:
		sh = DEFAULT_SHAPE
	dirt = _int_of(g.get("dirt"), 0, WeaponViewmodel.DIRT_MAX, -1)
	suppressed = g.get("suppressed", false) == true
	var gr := WeaponViewmodel.grime_for(dirt)
	var built := model == null or sh != shape
	if built:
		_build_model(sh, gr)
	elif gr != grime:
		for m: ShaderMaterial in _grime_mats:
			m.set_shader_parameter("grime", gr)
	grime = gr
	gun_type = t
	rounds = _int_of(g.get("rounds"), 0, MAX_ROUNDS, -1)
	_sync_count()
	var ms := GunMods.mods_of(g)
	if built or ms != mods:
		mods = ms
		GunMods.dress(model, shape, mods)
	var f: Variant = g.get("faults")
	var j := WeaponViewmodel.jam_of((f as Array).slice(0, MAX_FAULTS)) if f is Array else ""
	_find_rows(s, t)
	_vises = Vise.near(s, tables)
	if shown and not _vises.is_empty() and not clamped():
		_ask_hint("vr_vise")
	if shown and not mods.is_empty():
		_ask_hint("vr_mod_off")
	if clamped() and not int(vise["uid"]) in _vises:
		_unclamp(UNCLAMPED)   # the vise is gone from reach
	if not _take_mod.is_empty():
		_take_off(s)
	if j != jam:
		jam = j
		_clearing = ""   # a new jam (or none): the next rack may ask again
		_clear_left = 0.0
		if j != "":
			var c := rig.main_ctrl()
			rig.feel(c)
			rig.say(_index(c), jam_note(j))
	_pose_parts()
	_sync_mag()


## The round count over the grip: the loaded rounds CDDA sends (player_gun.rounds, its magazine's too), red at 0;
## hidden for a gun that takes no ammo (no `rounds`) or a bad value.
func _sync_count() -> void:
	if count == null or not is_instance_valid(count):
		return
	count.visible = rounds >= 0
	count.text = str(maxi(rounds, 0))
	count.modulate = EMPTY_COLOR if rounds == 0 else Color.WHITE


## No gun wielded: the model goes (an item action in flight still lands through its signals).
func _clear() -> void:
	_drop_copy()
	if model != null:
		remove_child(model)
		model.free()
	model = null
	count = null   # freed with the model
	mods = []      # their boxes too
	ghost = null   # and the ghost
	fit = {}
	_pull = {}
	_take_mod = {}
	vise = {}
	_vises = []
	shape = ""
	gun_type = 0
	gun = null
	mag = null
	rounds_in = null
	rounds = -1
	dirt = -1
	grime = 0.0
	jam = ""
	suppressed = false
	_flash = null   # freed with the model
	_flash_t = 0.0
	_local = {}
	_half = {}
	_rest = {}
	_grime_mats.clear()
	_rack = {}
	fire_wait = 0.0


func _build_model(sh: String, gr: float) -> void:
	_drop_copy()
	if model != null:
		remove_child(model)
		model.free()
	model = WeaponViewmodel.build(sh, gr)
	add_child(model)
	shape = sh
	ghost = null   # went with the old model
	_pull = {}
	count = Label3D.new()   # goes with the model
	count.name = "RoundCount"
	count.pixel_size = COUNT_PX
	count.font_size = 32
	count.outline_size = 8
	count.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	count.no_depth_test = true   # over the gun's own meshes
	count.render_priority = 4
	count.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var grip := model.get_node_or_null("Grip") as Node3D
	count.position = (grip.position if grip != null else Vector3.ZERO) + COUNT_OFF
	count.visible = false
	model.add_child(count)
	_flash = null   # the old one went with the old model
	_flash_t = 0.0
	var muzzle := model.get_node_or_null("Muzzle") as Node3D
	if muzzle != null:
		_flash = WeaponViewmodel.build_flash(WeaponViewmodel.FLASH_SIZE.get(sh, 0.1))
		muzzle.add_child(_flash)
	_grime_mats = WeaponViewmodel.grime_materials(model)
	_local = {}
	_half = {}
	_rest = {}
	_rack = {}
	for part: String in PARTS:
		var n := model.get_node_or_null(part) as Node3D
		if n == null:
			continue
		_local[part] = model.transform * n.transform
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh is BoxMesh:
			_half[part] = (mi.mesh as BoxMesh).size * 0.5
		if part in RACK_PARTS:
			_rest[part] = n.position
	if not _local.has("Grip"):
		_local["Grip"] = Transform3D.IDENTITY
	if not _local.has("Muzzle"):
		_local["Muzzle"] = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -0.3))


## The wielded gun's carried row (type t) and what is in it: the first magazine and the first rounds directly under
## it (gunmods and anything the id tables don't know are left out).
func _find_rows(s: Snapshot, t: int) -> void:
	gun = null
	mag = null
	rounds_in = null
	if s == null:
		return
	var c := s.carried
	var cs := Snapshot.CARRIED_STRIDE
	var n := mini(c.size(), Snapshot.MAX_CARRIED * cs)
	var tables := rig.world.tables
	for k in range(0, n - cs + 1, cs):
		if gun == null:
			if (c[k + 4] & Snapshot.CARRIED_WIELDED) != 0 and c[k + 1] == t:
				gun = _ref(s, k)
			continue
		if c[k + 2] != gun.uid:
			continue
		var d: IdTables.Def = tables.def_at("itype", int(c[k + 1])) if tables != null else null
		var cat := d.category if d != null else ""
		if cat == "magazines" and mag == null:
			mag = _ref(s, k)
		elif cat == "ammo" and rounds_in == null:
			rounds_in = _ref(s, k)


## The carried row at index k of s.carried as an ItemRef.
static func _ref(s: Snapshot, k: int) -> ItemRef:
	var c := s.carried
	return ItemRef.on_player(c[k], int(c[k + 1]), c[k + 2], int(c[k + 3]), int(c[k + 4]), s.player_pos)


## Carried item `uid` in s as an ItemRef, null when it isn't carried (or listed).
static func _carried_ref(s: Snapshot, uid: int) -> ItemRef:
	if s == null or uid <= 0:
		return null
	var c := s.carried
	var cs := Snapshot.CARRIED_STRIDE
	for k in range(0, mini(c.size(), Snapshot.MAX_CARRIED * cs) - cs + 1, cs):
		if c[k] == uid:
			return _ref(s, k)
	return null


## The model in the main hand (kick included) and _hold.
func _place() -> void:
	_update_hold()
	var g: Vector3 = (_local.get("Grip", Transform3D.IDENTITY) as Transform3D).origin
	var kick := Transform3D(Basis(Vector3.RIGHT, KICK_ROT * _kick), Vector3(0.0, 0.0, KICK_BACK * _kick))
	transform = _hold * Transform3D(Basis.IDENTITY, g) * kick * Transform3D(Basis.IDENTITY, -g)   # about the grip


func _update_hold() -> void:
	if clamped():
		_hold = vise["pose"]   # held still by the vise
		return
	var g: Vector3 = (_local.get("Grip", Transform3D.IDENTITY) as Transform3D).origin
	_hold = hold_pose(grip_pose(rig.main_ctrl()), g)


## Slide / bolt at rest, or held open by a jam (the one being racked follows the hand instead).
func _pose_parts() -> void:
	if model == null:
		return
	for part: String in _rest:
		if not _rack.is_empty() and _rack.get("part") == part:
			continue
		var n := model.get_node_or_null(part) as Node3D
		if n != null:
			n.position = (_rest[part] as Vector3) + Vector3(0.0, 0.0, WeaponViewmodel.JAM_BACK if jam != "" else 0.0)


## The gun's Magazine part shows while something is in it and no copy rides in the off hand.
func _sync_mag() -> void:
	var m := model.get_node_or_null("Magazine") as Node3D if model != null else null
	if m != null:
		m.visible = loaded() and _copy == null


## How far point p (world) is from a part's box (0 inside), INF without that part.
func _box_dist(part: String, p: Vector3) -> float:
	if not _local.has(part):
		return INF
	var l := part_pose(part).affine_inverse() * p
	var h: Vector3 = _half.get(part, Vector3.ZERO)
	var d := (l - l.clamp(-h, h)).length()
	return d if is_finite(d) else INF


## The fire-mode target request showing, null for none.
func _fire_request() -> TargetRequestWidget:
	if aim == null or aim.request_ui == null:
		return null
	var t := aim.request_ui.target_widget()
	return t if t != null and t.mode == "fire" else null


## A fire request the client can't fly (another gun firing, no figures to test, a stop in our own square): plain
## FIRE at the square the muzzle's line meets, the cursor moved there first (as AimController.on_fire moves it to
## the crosshair's), never at CDDA's own pick. False, nothing sent: the line meets nothing, or the player's own
## square (pointed at the floor at your feet).
func _fire_plain(t: TargetRequestWidget) -> bool:
	var sq: Variant = muzzle_square()
	var s := rig.world.snapshot
	if not sq is Vector3i or s == null or sq == s.player_pos or aim.request_ui == null \
			or not aim.request_ui.set_target_cursor(sq):
		return false
	aim.shot_aim = {}   # this trigger pull replaces the kept aim: CDDA rolls its shots
	t.fire()
	_on_fired()
	return true


## The square the muzzle's line meets (AimController's LookRay, as the crosshair picks), null for none.
func muzzle_square() -> Variant:
	var pose := live_pose()
	if pose.is_empty() or aim == null or aim.look_ray == null:
		return null
	var r := aim.look_ray.cast(pose["origin"], pose["sight"])
	return r.get("square") if r.get("hit", false) and r.get("square") is Vector3i else null


## Waiting for the request of the `fire` the trigger queued: fire from the muzzle as soon as it shows. One it
## can't fly waits for the next trigger pull (never a plain FIRE nobody aimed).
func _tick_fire(d: float) -> void:
	fire_wait = maxf(fire_wait - d, 0.0)
	var t := _fire_request()
	if t == null:
		return   # still waiting, or (at 0) CDDA never asked where: given up
	fire_wait = 0.0
	var pose := live_pose()
	if pose.is_empty() or not aim.fire_from(pose["origin"], pose["sight"]):
		rig.feel(rig.main_ctrl())   # the request stays: the next pull fires at the muzzle's square


## The slide / bolt follows the off hand back along the bore; the farthest pull is kept for the let go.
func _tick_rack() -> void:
	var c := rig.left if int(_rack["hand"]) == 0 else rig.right
	var pull := (_hold.affine_inverse() * c.global_position).z - float(_rack["start"])
	if not is_finite(pull):
		return
	_rack["max"] = maxf(float(_rack["max"]), pull)
	var part: String = _rack["part"]
	var n := model.get_node_or_null(part) as Node3D
	if n != null and _rest.has(part):
		n.position = (_rest[part] as Vector3) + Vector3(0.0, 0.0, clampf(pull, 0.0, RACK_TRAVEL))


## The off hand brings a magazine (or rounds) to the well, turned its way: reload with it; the hand lets it go.
func _try_insert() -> void:
	if rig.hands == null or actions == null or gun == null or not _op.is_empty() or not _local.has("MagWell"):
		return
	var c := rig.off_ctrl()
	var id := rig.hand_id(c)
	var it: ItemRef = rig.hands.holding(id).get("item")
	var well := part_pose("MagWell")
	var dist := c.global_position.distance_to(well.origin)
	if dist > REARM_M:
		_rearm = true
	if it == null or not _rearm or not (dist <= MAG_IN_M) or not it.carried or actions.pending(it.uid) != "":
		return
	if not loadable(it, rig.world.tables):
		return
	if c.global_basis.orthonormalized().y.dot(well.basis.orthonormalized().y) < MAG_IN_DOT:
		return
	_rearm = false
	rig.hands.release(id, {})   # the hand lets go, nothing sent: CDDA has it in the off hand until the reload lands
	var o := {"op": "reload", "uid": gun.uid, "item": it}
	_op = o
	if actions.reload(gun, it):
		return
	if is_same(_op, o):
		_op = {}
	_readopt(it)
	rig.feel(c)


## Magazine out into CDDA's off hand; its copy rides in the off hand until it lands.
func _unload(c: XRController3D) -> void:
	_rearm = false   # it comes out at the well: no putting it straight back
	var o := {"op": "unload", "uid": gun.uid, "mag": mag.uid}
	_op = o
	_show_copy()
	if actions.unload(gun, "off"):
		return   # (MockItems answers inside the call: _on_finished / _on_refused ran already)
	if is_same(_op, o):
		_op = {}
	_drop_copy()
	rig.feel(c)


func _show_copy() -> void:
	_drop_copy()
	var m := model.get_node_or_null("Magazine") as MeshInstance3D if model != null else null
	if m == null:
		return
	_copy = MeshInstance3D.new()
	_copy.name = "MagazineCopy"
	_copy.mesh = m.mesh
	_copy.top_level = true
	_copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_copy)
	_copy.transform = rig.off_ctrl().global_transform
	_sync_mag()


func _drop_copy() -> void:
	if _copy != null and is_instance_valid(_copy):
		remove_child(_copy)
		_copy.free()
	_copy = null
	_sync_mag()


## Hands an item back to the off hand (or hand i) while CDDA still has it (a refused or unsent reload or mod).
func _readopt(it: ItemRef, i := -1) -> void:
	var c := rig.off_ctrl() if i < 0 else (rig.left if i == 0 else rig.right)
	var id := rig.hand_id(c)
	if rig.hands == null or not rig.hands.holding(id).is_empty():
		return
	var now := _carried_ref(rig.world.snapshot, it.uid)
	if now == null:
		return
	rig.hands.set_hand_pose(id, c.global_transform, true)
	rig.hands.adopt(id, now)


## The magazine landed in CDDA's off hand: the off hand holds it (Hands.adopt); with the grip let go meanwhile (hold
## setting) it is let go like any held item.
func _take_out(mag_uid: int) -> void:
	var it := _carried_ref(rig.world.snapshot, mag_uid)
	var c := rig.off_ctrl()
	var id := rig.hand_id(c)
	if it == null or not it.is_off_hand() or rig.hands == null or not rig.hands.holding(id).is_empty():
		return
	rig.hands.set_hand_pose(id, c.global_transform, true)
	if rig.hands.adopt(id, it) and rig.settings["grip"] != "toggle" and not rig.grip_down(c):
		rig.let_go(c, false)   # never thrown: the magazine just landed in the hand


func _on_finished(item: ItemRef, op: String) -> void:
	if _op.is_empty() or item == null or item.uid != _op.get("uid") or op != _op.get("op"):
		return
	var o := _op
	_op = {}
	_drop_copy()
	if op == "unload":
		_take_out(int(o.get("mag", 0)))
	elif op == "mod_remove":
		_take_mod = {"uid": o["uid"], "hand": o["hand"]}


func _on_refused(item: ItemRef, op: String, reason: String) -> void:
	if op == "clear" and item != null and gun != null and item.uid == gun.uid and _clearing != "":
		_clearing = ""   # CDDA wouldn't clear the jam a rack asked for: its reason by the racking hand, and the
		_clear_left = 0.0   # next rack may ask again
		var oc := rig.off_ctrl()
		rig.feel(oc)
		rig.say(_index(oc), reason)
		return
	if _op.is_empty() or item == null or item.uid != _op.get("uid") or op != _op.get("op"):
		return
	var o := _op
	_op = {}
	_drop_copy()   # a magazine coming out snaps back into the gun
	var hi := int(o.get("hand", -1))   # a mod's: the hand that let it go or pulled it
	var c := rig.off_ctrl() if hi < 0 else (rig.left if hi == 0 else rig.right)
	rig.feel(c)
	rig.say(_index(c), reason)
	if op in ["reload", "mod_add"] and o.get("item") is ItemRef:
		_readopt(o["item"], hi)
	var bx: Variant = o.get("box")
	if op == "mod_remove" and is_instance_valid(bx):
		(bx as Node3D).position = o["rest"]   # it stays on the gun
	if op == "mod_add" and o.get("fit") is Dictionary:
		_hint = str((o["fit"] as Dictionary).get("text", ""))   # CDDA's reason stays by the hand a while
		_hint_left = HINT_S


func _on_fired() -> void:
	if not shown or rig == null:
		return
	_kick = 1.0
	kicks += 1
	rig.feel(rig.main_ctrl(), SHOT_AMP, SHOT_S)


## A round CDDA fired (AimController.shot_went): the muzzle flash, unless the gun isn't in the hand, flashes are off,
## it has a suppressor, or the last flash was under FLASH_GAP_S ago.
func _on_shot_went() -> void:
	if not shown or _flash == null or not flashes or suppressed or _flash_wait > 0.0:
		return
	_flash_t = WeaponViewmodel.FLASH_S
	_flash_wait = WeaponViewmodel.FLASH_GAP_S
	_flash.rotation.z = randf() * TAU
	flashed += 1
	WeaponViewmodel.show_flash(_flash, 1.0)   # at once, not on the next frame


## Fades the flash out and counts down the gap to the next one; off, it goes at once.
func _tick_flash(d: float) -> void:
	_flash_wait = maxf(_flash_wait - d, 0.0)
	_flash_t = maxf(_flash_t - d, 0.0) if flashes else 0.0
	WeaponViewmodel.show_flash(_flash, _flash_t / WeaponViewmodel.FLASH_S)


## The player's trigger pull fired no round (HitFeedback.misfired): no recoil, a dry click in the hand.
func _on_misfired(_jammed: bool) -> void:
	if not shown or rig == null:
		return
	_kick = 0.0
	misfires += 1
	rig.feel(rig.main_ctrl(), CLICK_AMP, CLICK_S)


## The player's projectile hit (HitFeedback.shot_confirmed: CDDA's damage, the player's projectile; a throw too, which
## the event can't tell from an arrow): while the gun shows in the main hand, a thump there, a strong one for a kill.
## A melee hit never comes here.
func _on_hit(_uid: int, _part: String, _amount: int, killed: bool) -> void:
	if not shown or rig == null:
		return
	hits += 1
	rig.feel(rig.main_ctrl(), KILL_AMP if killed else HIT_AMP, KILL_S if killed else HIT_S)


func _index(c: XRController3D) -> int:
	return 0 if c == rig.left else 1


## A whole number from snapshot data in lo..hi, else `dflt`.
static func _int_of(v: Variant, lo: int, hi: int, dflt: int) -> int:
	var n := 0
	if v is int:
		n = v
	elif v is float and is_finite(v) and v == floorf(v) and absf(v) < 9.0e15:
		n = int(v)
	else:
		return dflt
	return n if n >= lo and n <= hi else dflt
