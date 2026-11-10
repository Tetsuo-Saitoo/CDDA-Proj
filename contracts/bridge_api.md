# Bridge API (GDExtension `CddaSim`)

The DLL `client/bin/fp3d_cdda.windows.x86_64.dll` (loaded by `client/bin/fp3d_cdda.gdextension`) runs CDDA
inside the Godot process on its own thread and registers one class, `CddaSim` (a `RefCounted`). CDDA's state is
global, so every `CddaSim` talks to the same single game. Source: `bridge/src/`; build: `docs/BUILD.md`.

Scripts should not name `CddaSim` as a type (the client must still load when the DLL isn't built): check
`ClassDB.class_exists("CddaSim")` and use `ClassDB.instantiate("CddaSim")`. `client/scripts/live/live_session.gd`
wraps it for the client.

All methods are non-blocking except `stop()`. Everything is polled; there are no signals.

| Method | Returns | Notes |
|---|---|---|
| `start(data_dir, user_dir, world)` | `String` | "" when started, otherwise why not. `data_dir`: absolute, holds `data/json` (the `cdda/` folder). `user_dir`: absolute, made if missing; config, saves and `config/debug.log` go there. `world`: 1-32 of `A-Z a-z 0-9 _ -`; a new world with a random character starts. **An existing world of exactly that name is deleted first if the name starts with `fp3d-` and a start like this made it** (FP3D's throwaway worlds: `--quick`, the tests; boot leaves the file `fp3d_made_this_world.txt` in them; a world of that name without it, a player's or an older FP3D's, is left alone and the game starts in the first free or marked `<name>-2`, `-3`, ... instead); any other name in use, ignoring case, makes the start fail (state `failed`, "world <name> exists"). `start_new_game` refuses new world names starting with `fp3d-` in any case. Once per process. |
| `start_load(data_dir, user_dir, world, save)` | `String` | Like `start`, but loads the saved character `save` from the existing `world` (CDDA's main-menu load path). **Deletes nothing.** `world` and `save` must be names `list_worlds` / `list_saves` give for `user_dir`; anything else is refused at once. Once per process (either `start` or `start_load`). |
| `start_new_game(data_dir, user_dir, world, fresh_world, chargen, world_setup = false)` | `String` | `world_setup` (fresh worlds only): ask for the world's settings and mods with a `world_setup` request first. A new game. `fresh_world` true: world `world` is made; never replaces one: a name in use, ignoring case and whether or not `list_worlds` shows it, makes the start fail ("world <name> exists"; the client's MainMenu should refuse taken names first, ignoring case). Nothing is written before the world setup is answered. False: a new character in the existing `world` (a name `list_worlds` gives; nothing deleted). `chargen` true: the character comes from a `chargen` request (ui_requests.md) instead of CDDA's random "play now" one. Once per process. |
| `list_worlds(user_dir)` | `PackedStringArray` | Worlds in `user_dir/save/` (folders holding `worldoptions.json` or `master.gsav`), sorted, max 256. Reads the folders directly, so it works before a start. Skips symlinks/junctions and names that aren't plain UTF-8 text or could be paths (`/ \ : * ? " < > |`, leading `.`/space, trailing `.`/space, > 128 bytes). A missing folder gives `[]`; a relative path gives `[]` and an error. |
| `list_saves(user_dir, world)` | `PackedStringArray` | Characters saved in `world` (the save id CDDA shows), sorted, max 256. Only files named `#<CDDA base64>.sav` or `.sav.zzip` whose name decodes to plain text (no control characters, not starting with `#`) and encodes back to the same file. |
| `stop()` | | Shuts the game down and waits for its thread. While booting this waits until loading is done (up to ~30 s). The extension calls it on unload. No restart afterwards (once per process). |
| `get_state()` | `String` | `idle`, `booting`, `running`, `ended` (death or quit), `failed` (an exception), `stopped`. |
| `get_error()` | `String` | Why it ended or failed: `saved and quit`, `the character died`, `the game ended`, or the exception text. |
| `get_request()` | `Dictionary` | The pending UI request, `{}` if none. Fields as in `ui_requests.md`: `id`, `kind` (key, menu, popup, string, item_select, item_multi, direction, target, world_setup, chargen, shot), `context`, `title`, `text`, `entries` (Array of `{id, label, enabled, description}`), `actions` (PackedStringArray), `allow_cancel`, `max_len`, `mode`, `status`, `origin`, `cursor` (Vector3i), `range`, `allow_vertical`, `candidates` (Array of Vector3i), `timed`, `turn`, `paused`, `pause_reason`. Target requests add `weapon_wielded` (bool) and, firing a gun, `dispersion` / `dispersion_typical` (float arcmin, only when > 0); shot requests add `shot_error`, `shot_angle` (degrees) and `dispersion` (floats; client-flown shots in `ui_requests.md`). Compare `id` to see a new one. |
| `answer(d)` | `bool` | Answers the pending request. `d`: `id` (int, required), optional `cancel` (bool), `action` (String, ≤64 bytes), `entry` (int), `text` (String, ≤1024 bytes), `picks` (Array of `[entry id, count]`, count 0 = all, ≤4096), `pos` (Vector3i), `shot` (target and shot requests: Dictionary `{end` (Vector3i, required), `hit_uid` (int), `part` (String, ≤64 bytes), `quality` (float, 0..0.99), `fly` (target only; a bool, anything else = false)`}`). Any field of the wrong type → `false` and nothing is sent. Strings lose control characters. A stale `id` is ignored by the sim. |
| `queue_action(action)` / `clear_actions()` / `get_queued_actions()` | `bool` / / `int` | The action queue (`ui_requests.md`): main-loop action names (`UP`, `pause`, `LEVEL_UP`, ...), max 32. |
| `queue_item_action(d)` | `bool` | One item by its snapshot handle, no menus (see "Single items" below). `d`: `op` ("take", "put", "drop", "unload", "reload", "clear"), `item` + `type` (uid and itype index from the snapshot, ints), `pos` (Vector3i: the square to take from or drop on, where a put's container or an unload's item lies, or where a reload's ammo lies; required for take and drop, used only for what isn't carried), `hand` ("pack" default, "main", "off"; take only), `container` + `container_type` (put, required; reload: the ammo or magazine to load with, required), `pocket` (put, -1 = CDDA's pick, else 0..255 as the snapshot gives it), `spot` (Vector2, each 0..1 across the square; drop only, optional). A missing key, a wrong type or anything out of range (uid 1..2^53−1) → `false`, nothing queued; also false when the queue is full. Unload (CDDA's moves): a gun gives its magazine whole, a magazine its rounds, to `hand`; loaded gunmods come after the item itself, one per action; liquids refused. Reload (CDDA's reload activity and moves): `item` must be carried; loads the first part CDDA's reload menu would offer (the item, the magazine in it, then gunmods), as much as fits; refused with a message when incompatible, the same item, out of reach, sealed, or when the loaded item wouldn't fit where it is. Clear: `item` must be the wielded gun itself (not carried elsewhere, lying around, or inside it); clears its jam (CDDA's `gun_mechanical_simple` faults) with CDDA's mend: the jam's first fix the character can do, its time (10 s for each jam in CDDA's data); refused with a message when not wielded, not jammed, busy, or no fix can be done; `pos`, `hand` and `container` aren't used. Shares the action queue. |
| `get_snapshot_seq()` | `int` | seq of the newest snapshot, 0 before the first. A snapshot is taken right before every request but `shot`. |
| `get_snapshot_json(z_below, z_above)` | `String` | The newest snapshot as `snapshot.md` JSON, levels from the player's z − `z_below` to z + `z_above`. "" before the first. Treat as hostile input like any snapshot (`Snapshot.parse_text`). |
| `get_id_tables_json()` | `String` | `id_tables.md` JSON; "" before the data has loaded. Fetch again when a snapshot's `ids_generation` changes. |
| `drain_events()` | `Array` | Events since the last call (`events.md`), each a Dictionary: `kind` (sound, message, attack, damage, projectile, explosion, death, anim, turn_end), `turn`, `seq`, `uid`, `other`, `pos` (Vector3i), `amount`, `heard`, `type`, `detail`, `text`, `path` (Array of Vector3i). Drain every frame: the queue holds 4096. |
| `get_events_dropped()` | `int` | Events lost to overflow since start. |
| `get_clock()` | `Dictionary` | `real_time`, `timescale`, `paused`, `pause_reason`, `auto_pause` (bool, the setting below). |
| `set_real_time(on)` / `set_timescale(s)` / `set_paused(on)` / `interrupt()` | | The clock (`ui_requests.md`); timescale clamps to 0.25-16. |
| `set_auto_pause(on)` | | Real time pauses itself ("hostile spotted") when a new hostile comes into view. On by default; only acts in real time. Its own setting: CDDA's safe mode is off in FP3D games (the `safemode` action, Shift+1, still toggles it). |
| `save_game(only_if_changed = false)` | `bool` | Saves the game where it stands and plays on (CDDA's quicksave, no popup). The sim saves at the main loop's next request, even while paused; in another prompt or a long activity it waits for that. `only_if_changed` (autosave) skips it when nothing happened since the last save. False unless the game is `running`. |
| `get_held()` | `Dictionary` | What the hands hold: `seq` (bumps on every update: before each request but `shot` and once per turn, also during activities), `turn`, `main` and `off` (`{}` when empty, else `id`, `name`, `liquid` ("" none), `ml` and `capacity_ml` (0: not a container)), `activity` (the avatar's activity id, "" none). Names are capped at 128 bytes. |
| `set_cheats_allowed(on)` | — | Cheats and test kits work only after this (off at start): the client turns it on for test-range games or when the player's own debug cheats switch is on, and off again when that switch goes off (requests not applied yet are dropped; cheats already on stay on). The first cheat turned on, or kit given, turns that game's achievements off for good, as CDDA's debug menu does ("Achievements have been disabled."). |
| `set_cheat(name, on)` | `bool` | Turns a testing cheat on or off for the character (`fp3d/cheats.h`; applied at the main loop's next request, also while paused; message "Cheat <name> on/off."). Names: `invincible` (takes no damage, can't die), `no_needs` (hunger, thirst, sleepiness held), `no_weight_limit`, `unlimited_ammo` (the wielded gun refills every turn), `stamina`, `no_temperature`, `night_vision` (also reveals the map). All off until turned on; they stay with the character in its save. False for any other name, while cheats aren't allowed (`set_cheats_allowed`), while no game runs, or after shutdown. |
| `get_cheats()` | `Dictionary` | `seq` (bumps before every request and once per turn), `cheats` ({name: bool} for every name above), `kits_given` (test kits handed out since start), `allowed` (`set_cheats_allowed`). |
| `give_test_kit()` | `bool` | Gives the character the test loadout at the main loop's next request: a big backpack worn, a loaded Glock 19, Remington 870 and SCAR-L with spare magazines and ammo, machete, combat knife, crowbar, hammer, screwdrivers, multitool, lighter, flashlight, pot, bandages, 4 MREs, 3 bottles of water; what doesn't fit lands at its feet. False while cheats aren't allowed or no game runs. |
| `use_stairs(pos, dir)` | `bool` | Use the stairs at absolute square `pos` (Vector3i): `dir` 1 up, -1 down. The player must stand on that square or next to it on the same level; from next to it they step onto it first (CDDA's step), then CDDA's own stairs move (its costs, prompts and messages). Refused with a message, nothing done: too far, another level, no stairs that way there, a creature on the square, riding (except a mech) or inside a vehicle. Out-of-range `pos` (z outside -10..10) or another `dir` → `false`, nothing queued; also false when the queue is full. Shares the action queue. |
| `match_recipes(container)` | `int` | L9: asks what a container's contents can become and how long, without blocking (see "Recipe queries" below). `container`: `uid` + `type` (the handle and itype index from the snapshot, ints) and `pos` (Vector3i, the square it lies on; the avatar's square also finds carried containers). Returns the query id (≥ 1), or 0 when refused: a missing key, a wrong type or anything out of range (uid 1..2^53−1, type ≥ 1), 8 queries pending already, or no game running. |
| `take_query_result(id)` | `String` | The query's result as JSON (once; a second call gives ""), "" while it is pending or for an unknown id. Results wait until taken; beyond 16 the oldest is dropped. Each ≤ 64 KB. |
| `get_save_status()` | `Dictionary` | `pending` (asked, not finished), `done` (saves finished since start, skipped ones too), `ok` (the last one). The message log also gets "Game saved." or "The game could not be saved." |

Positions are absolute map squares (CDDA `tripoint_abs_ms`, y south), like the snapshot.

## Behaviour to know

- Recipe queries (L9, `cdda/src/fp3d/cooking.h`): the sim answers them at the main loop's request (right after
  the snapshot, and at once when one is posted while it waits there, also while paused) and once per turn
  during activities; one posted during another prompt (a menu, a popup) waits for the main loop. Poll
  `take_query_result` each frame until it gives text. Queries are read-only (nothing in the game changes).
  Result: `{"id": N, "ok": true, "error": "", "container": uid, "matches": [...]}`. Refused: `ok` false, `error`
  one of `out of reach` (not on the avatar's level within CDDA's crafting reach: 6 squares with a clear path, as
  crafting_inventory uses; checked first, so a query can't probe unreachable squares), `not found` (no item with
  that uid **and** itype on that square: gone, moved, or a stale handle), `not a container`, plus `internal` and
  `too large` (shouldn't happen), `matches` empty. Matching uses CDDA's rules: components come **only** from the
  container's contents (its CONTAINER pockets and what's nested in them); tools and qualities from the avatar's
  crafting inventory (what CDDA's craft menu sees in reach: carried, the ground, furniture, vehicles, fires) plus
  the container itself emptied (CDDA counts BOIL only on an empty pot). Only recipes that need heat (a tool of
  CDDA's `surface_heat` / `water_boiling_heat`) and take one of the contents as a component are looked at; a
  recipe matches when every component group is covered by the contents for a batch of 1. Each match:
  `recipe` (id), `result` (itype id), `name` (plain text, ≤ 128 bytes), `batch_max` (largest batch the
  contents cover, ≤ 20), `time_s` (CDDA's time for this character to craft one batch now, game seconds, with
  their crafting speed: light, morale, limbs, pain, helpers), `known` (the character can use the recipe: learned,
  or in a book in reach, or known by a helper, like CDDA's craft menu), `skills_ok` (skill levels the recipe asks
  for), `tools_ok` (tools and qualities there), `missing` (≤ 8 short texts: a missing tool group "fire or
  hotplate or ...", a quality "boiling 1", a skill "cooking 3", a required proficiency), `can_start` (known,
  tools there and required proficiencies; low skill does **not** block it, as in CDDA, where it only adds a
  failure chance). Order: `can_start` first, then the recipes using the most of the contents' kinds, then the
  largest batch, then by id. At most 32 matches.
- Boot takes ~30 s (data load, new game). The first snapshot arrives with the first request.
- Saving: `save_game()`, then watch `get_save_status().done` go up. Or queue the main-loop action `save` (CDDA's "save and quit"); it asks to confirm with a `popup`
  request, answer `action: "YES"`. The game then ends (`ended`, `saved and quit`). `start_load` in a new process
  resumes it: the first request has the saved turn and the player stands where they were.
- A loaded save's world uses its own options and mods; mods CDDA can't find come up as popup requests.
- Hand attacks (first person / VR, `cdda/src/fp3d/hands.h`): main-loop actions `fp3d_attack_main_<DIR>` and
  `fp3d_attack_off_<DIR>`, DIR one of the eight move actions (UP = north). Main hand: CDDA's melee attack with
  what is wielded; off hand: an unarmed strike (the `attack` event's `type` is 0), refused while the wielded item
  needs both hands or the left arm is broken. Nobody there or someone friendly: a message, no time.
- Held items and context use (`cdda/src/fp3d/held.h`): the off hand (left) holds one carried item, marked with
  the item var `fp3d_offhand` (it stays in its pocket for CDDA's rules; saves keep it; a token the avatar keeps
  too means an item that left the avatar isn't held again on return), empty while the wielded item needs both
  hands or the left arm is broken; an off-hand strike hits with it. Main-loop actions: `fp3d_hold_off` (an
  `item_select` prompt of one-handed items; a message when none fit), `fp3d_stow_off`, `fp3d_use_<DIR>`, first
  that fits: a hose (quality HOSE) in one hand and a container in the other siphon the vehicle on that square
  into the container with no menu (the tank there, else the only one with liquid, else a pick); a held
  container's liquid goes into a vehicle tank there that takes it (refuel); a held container fills from liquid
  there (river, lake, keg, barrel, puddle); anything else is CDDA's examine of that square. A liquid fill (`ACT_FILL_LIQUID`)
  runs one turn per second of wall time in both clock modes, so it can be watched.
- Single items (`cdda/src/fp3d/item_hands.h`, for VR hands, mouse grabbing and looting): the snapshot lists a
  handle (uid) for the first 32 items of each seen pile and for every carried item (`snapshot.md`). The uid is
  kept in the item var `fp3d_uid` (saves keep it; CDDA's stacking ignores it). `queue_item_action` sends one
  action; the sim finds the item again by uid **and** itype **and** square (or that it is carried) and refuses
  with a message (an `m_info` message event, no time spent) if it isn't there, out of reach (your square and the
  eight around it, same z) or CDDA says no: "too big", "too heavy", "can't contain liquid", a full main hand,
  someone else's item, a worn item ("Take off ... first"), no room on the square. It never opens a CDDA menu.
  Take: into the inventory (CDDA's best pocket, carry limit as CDDA's pickup), the main hand (CDDA's wield; refused
  while it holds something) or the off hand (held as `held.h`, kept as its own stack). Put: into a carried
  container (worn, wielded, held, or nested) or one lying in reach, CDDA's pocket rules and its parents' limits.
  Drop: on a square in reach; with `spot` the item keeps it in the item var `fp3d_spot` (permille, read back
  strictly and shown in the snapshot) and the message says "put down"; picking it up forgets it. All take CDDA's
  move costs (obtain + move cost). A stack counted by charges (ammo, rocks) moves as a whole; put into a pocket it
  can merge with the same thing and take that stack's uid.
- CDDA's debug message prompts and "press any key" screens come as `key` requests with context `RAW_KEY` and no
  actions; answer `action: " "`. The message itself is in `debug.log`.
- CDDA's window still exists, hidden, with SDL's software renderer (B2 tech debt); it is created and destroyed
  on the game thread, which also calls `SDL_Quit()` before it ends (see TASKS.md "Bridge facts").
- The DLL links everything statically (vcpkg `x64-windows-static`, static CRT): it imports only system DLLs.
- `get_snapshot_json` builds the JSON on the calling thread (~tens of ms for 3 levels); call it only when the seq
  changes.
