class_name GunModFit
extends RefCounted
## Gun modification on the flat screen (F1, user 2026-11-17): what E and the Tab view need to fit a carried gunmod
## onto the wielded gun or take one off. CDDA decides everything (ItemActions.mod_add / mod_remove: its install
## rules, questions, odds and time); this only reads the snapshot's wielded_gun `fits` / `mods` and the id tables, so
## a "no" CDDA already gave is said at once instead of sent.

const IRREMOVABLE := 1   # wielded_gun.mods flags: irremovable or integral
const FITTING := "Fitting the %s."
const FITTING_ODDS := "Fitting the %s: %d%% (%d%% risk of damage)."
const NO_FIT := "That doesn't fit your %s."


## True when carried `it` is a gunmod (its id table entry has a `gunmod_location`).
static func is_gunmod(it: Variant, tables: IdTables) -> bool:
	if not it is ItemRef or tables == null:
		return false
	var d := tables.def_at("itype", (it as ItemRef).type)
	return d != null and not d.gunmod_location.is_empty()


## The wielded gun in `main` and a carried gunmod in `off` (HudData.held's hands): {gun, mod}; {} when the hands don't
## hold that pair (the gun must be the snapshot's wielded gun: ItemActions.gun_faults).
static func held_pair(main: Variant, off: Variant, snap: Snapshot, tables: IdTables) -> Dictionary:
	if not main is ItemRef or not off is ItemRef or not (off as ItemRef).carried or not is_gunmod(off, tables) \
			or (main as ItemRef).uid == (off as ItemRef).uid or ItemActions.gun_faults(snap, main) == null:
		return {}
	return {"gun": main, "mod": off}


## True when carried row `it` is the wielded gun (ItemActions.gun_faults).
static func is_wielded_gun(it: Variant, snap: Snapshot) -> bool:
	return it is ItemRef and ItemActions.gun_faults(snap, it) != null


## CDDA's judgement of carried gunmod `uid` against the wielded gun (wielded_gun `fits`): {uid, ok, chance, risk,
## reason}; {} when it isn't listed (an older bridge, or not carried: CDDA decides when asked).
static func fit_of(snap: Snapshot, uid: int) -> Dictionary:
	var fs: Variant = snap.player_gun.get("fits") if snap != null else null
	if not fs is Array:
		return {}
	for f: Variant in (fs as Array).slice(0, Snapshot.MAX_GUN_FITS):
		if f is Dictionary and (f as Dictionary).get("uid") == uid and (f as Dictionary).get("ok") is bool:
			return f
	return {}


## Why gunmod `uid` won't go on the wielded gun named `gun_name`, as CDDA said ("Your <gun> <reason>"); "" when it
## may (listed as fitting, or not listed).
static func refusal(snap: Snapshot, uid: int, gun_name: String) -> String:
	var f := fit_of(snap, uid)
	if f.is_empty() or f["ok"] == true:
		return ""
	var why := str(f.get("reason", ""))
	return "Your %s %s" % [gun_name, why] if not why.is_empty() else NO_FIT % gun_name


## The line once a fit is asked for: the odds when CDDA gives them under 100 %.
static func fitting_line(snap: Snapshot, uid: int, mod_name: String) -> String:
	var f := fit_of(snap, uid)
	var chance := int(f.get("chance", 100)) if f.get("chance") is int else 100
	if chance < 100:
		return FITTING_ODDS % [mod_name, chance, int(f.get("risk", 0)) if f.get("risk") is int else 0]
	return FITTING % mod_name


## The wielded gun's installed mods (wielded_gun `mods`, checked again: GunMods.mods_of): [{uid, type, location,
## flags}]; [] when `gun` isn't the wielded gun or the snapshot sends none.
static func mods_on(snap: Snapshot, gun: Variant) -> Array[Dictionary]:
	if snap == null or not is_wielded_gun(gun, snap):
		return [] as Array[Dictionary]
	return GunMods.mods_of(snap.player_gun)
