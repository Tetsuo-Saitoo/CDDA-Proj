# Snapshot (sim → client)

An immutable copy of the reality bubble. The sim thread captures one (`fp3d::capture_snapshot`) after every
player action and at turn ends, and publishes it (`publish_snapshot`); the client always reads the newest
(`latest_snapshot`, a `shared_ptr<const snapshot>`). Implemented in `cdda/src/fp3d/snapshot.h` (block B3).

Source in CDDA: `map` (`map_scale_constants.h`: `SEEX = 12`, `MAPSIZE = 11`, z from `-OVERMAP_DEPTH` (-10) to
`OVERMAP_HEIGHT` (10)), `avatar`, `map::get_vehicles`, lightmap/visibility caches, map memory, `weather_manager`,
`calendar`.

**No deltas to lose.** Every snapshot lists all 11 × 11 × 21 submaps. A submap that didn't change since the
previous capture is the *same object* (shared pointer) with the same revisions, so a snapshot costs little and
a client that skips snapshots still sees every change. The client keeps, per submap position, the revisions it
last built and rebuilds:
- the mesh when `revision` changes (ter / furn / trap / flags);
- overlays (light, visibility, item piles, fields, heat, cookware, lights) when `detail_revision` changes.

A submap that leaves the bubble is forgotten; if it comes back it restarts at revision 1 (the client should
rebuild on any revision it didn't build, not only on increases).

```cpp
struct snapshot {
    uint32 contract_version;      // 0
    int64  turn;                  // game turns since the cataclysm, 1 turn = 1 s
    uint64 seq;                   // +1 per capture
    uint32 ids_generation;        // the id tables (id_tables.md) its indices belong to
    ui_point bubble_origin;       // absolute submap at bubble (0,0); z = 0
    player_view player;
    std::vector<shared_ptr<const submap_view>> submaps;   // 121 per level taken; all 2541, z -10..10, unless the host
                                  // wants fewer levels (fp3d::want_snapshot_levels: the bridge takes the widest range
                                  // get_snapshot_json was asked for). A level left out keeps its revision counters.
                                  // (JSON: top-level "z_levels": [-10, 10], the map's range)
    int8 z_first, z_last;         // the levels `submaps` holds (not in the JSON)
    std::vector<creature_view> creatures;   // perceived only, player first   (cap 1024)
    std::vector<vehicle_view>  vehicles;    // all in the bubble (physical, like terrain) (cap 256)
    environment_view env;
};

struct submap_view {              // parallel arrays, index = y * 12 + x
    ui_point pos;                 // absolute submap
    uint32 revision, detail_revision;
    uint32 ter[144], furn[144];   // CDDA int ids (0 = t_null / f_null)
    uint32 trap[144];             // CDDA int id, only traps the player knows or sees now (0 = none)
    uint8  light[144];            // CDDA light level, clamped 0..255
    uint8  vis[144];              // 0 never seen, 1 remembered, 2 seen now (lit), 3 in sight but too dark
    uint8  flags[144];            // bit0 roof (not outside), bit1 no floor (open air / hole), bit2 sign, bit3 vehicle part
    std::vector<item_pile_view> items;   // tiles with vis == 2 only (cap 144)
    std::vector<field_view>     fields;  // tiles with vis == 2 only (cap 4 per tile)
    std::vector<heat_view>      heat;      // tiles with vis == 2 only (cap 32)
    std::vector<cookware_view>  cookware;  // on those heat tiles where CDDA shows items (could_see_items; cap 16)
    std::vector<light_view>     lights;    // tiles with vis == 2 that add light (cap 16, brightest first)
};
struct light_view     { uint8 tile; uint8 luminance; uint8 kind; };
    // C6: the strongest light source on the square, as CDDA's lightmap gathers it. luminance = CDDA luminance,
    // rounded, 0..255. kind: 0 terrain/furniture (light_emitted), 1 an item lying there (lamp, lit candle...),
    // 2 a field (fire and other glowing fields). Ties keep tile order.
struct item_pile_view { uint8 tile; uint16 count; uint32 top[4]; uint32 corpse; uint16 corpse_state;    // itype indices, largest volume first; corpse = mtype of the largest body (0 none); corpse_state bits: 1 bled, 2 field dressed, 4 dressing failed, 8 skinned, 16 quartered, 32 pulped, 64 gibbed
                        std::vector<item_handle_view> handles; };   // the first 32 items (256 on the player's square and the 8 around it, same level), CDDA's stack order
struct item_handle_view { uint64 uid; uint32 type; int16 spot_x, spot_y; int16 yaw; bool side; int8 shelf; };   // uid 1..2^53-1 (bridge_api.md "Single items"); type = itype index; spot = where it was placed, permille of the square (x east, y south), -1 none; yaw/side = how it lies there (whole degrees 0..359, -1 no pose; JSON `poses`); shelf = the furniture shelf the client put it on (its own numbering 0..15, -1 none; JSON `shelves`); a changed spot, pose or shelf bumps detail_revision
struct field_view     { uint8 tile; uint32 type; uint8 intensity; uint16 age_turns; };   // type = CDDA int id
struct heat_view      { uint8 tile; uint8 source; uint32 tool; uint8 fire; int32 charges; bool lit; };
    // A square that gives heat to CDDA's crafting (L9, cdda/src/fp3d/cooking.h). source: 0 a fire alone (fd_fire, or
    // ter/furn flagged USABLE_FIRE), 1 furniture whose crafting pseudo item is a heat tool (fireplace, wood stove,
    // oven, smoker), 2 a vehicle part with one as a pseudo tool (kitchen unit hotplate, oven appliance).
    // tool = itype index of that heat pseudo tool (fake_fireplace, fake_woodstove, hotplate ...), 0 = only a fire;
    // fire = fd_fire intensity 0..3; charges = what CDDA's crafting inventory gives the tool there (fuel lying in a
    // fireplace or stove, battery power), clamped to int32; lit = CDDA's crafting would accept that heat now (a fire
    // burns, or the tool has charges). Heat tools are read from CDDA's `surface_heat` and `water_boiling_heat`
    // requirements at load, not a fixed list.
struct cookware_view  { uint8 tile; uint64 uid; uint32 type; std::vector<cookware_item_view> contents;
                        uint32 craft_result; std::string craft_recipe; uint16 craft_progress; };
    // An item with the COOK or BOIL quality lying on a heat square (top level of the map stack; vehicle cargo not
    // yet). uid = its handle, the same uid the pile's `handles` list. contents: its CONTAINER pockets, one level,
    // cap 16. An in-progress CDDA craft among the contents, else one the `cook` item action started for this pot
    // (it lies on the character's square or one next to it, next to the pot, naming the pot): craft_result = itype
    // index of the result (0 none), craft_recipe = recipe id ("" none), craft_progress = permille.
    // CDDA asks nothing while the craft activity runs (it fast-forwards); a snapshot then comes about every
    // 0.5 s of real time, so the progress moves in steps.
struct cookware_item_view { uint64 uid; uint32 type; int32 count; };   // count = charges if counted by charges, else 1

struct creature_view {
    uint64 uid;                   // 1 = player; NPC = 1<<32 | character_id; monsters/vehicles from 2<<32 up.
                                  // Stable while the creature stays in view; session-scoped (not saved).
    uint8  kind;                  // 0 player, 1 npc, 2 monster
    uint32 type;                  // mtype index (monsters) or 0
    ui_point pos;                 // absolute square
    float  facing_deg;            // 0 until block D1
    uint32 move_mode;             // move_mode index (characters) or 0
    uint8  hp_frac;               // 0..255
    uint32 wielded;               // itype index (characters) or 0
    uint8  attitude;              // CDDA's Attitude to the player (attitude_to): 0 hostile, 1 neutral, 2 friendly
                                  // (ANY and the player itself: 1). Sent since 2026-11-09; optional for older
                                  // bridges: without it the client counts monsters as hostile, people not.
    string name;                  // NPCs only (kind 1; the key is left out for the player and monsters): CDDA's
                                  // name for them, color tags and control characters removed, up to 40 columns
                                  // (160 bytes), never cut inside a character; may be "". Sent since 2026-11-16;
                                  // older bridges leave it out. Text from saves and mods: show it, never parse it.
};

struct vehicle_view {
    uint64 uid; ui_point pos;     // absolute square of the vehicle's position
    float face_deg, turn_deg;     // facing and the facing it is turning to
    float velocity;               // m/s
    string name;                  // color tags and control characters removed, up to 60 columns (240 bytes)
    std::vector<vehicle_part_view> parts;   // cap 4096
};
struct vehicle_part_view { int mount_x, mount_y; uint32 vpart; uint8 hp_frac; uint8 state; /* bit0 open, bit1 broken, bit2 enabled, bit3 gap filler */
                           int8 dx, dy, dz; };
    // JSON row: [mount_x, mount_y, vpart, hp_frac, state, dx, dy, dz] (2026-11-17; older bridges send the first 5).
    // (dx, dy, dz): the square the part is on, from the vehicle's `pos`; each -127..127. Place parts by it, not
    // by turning the mount by face_deg: CDDA turns mounts in steps along a ray around a pivot that isn't sent, so
    // the two differ at most angles. dz is 0 except on ramps, where a vehicle can have parts a level up or down.
    // The vehicle's own parts come first, in CDDA's order. Then its gap fillers (state bit3): while a vehicle
    // stands at an angle, CDDA puts a copy of an edge part (a board, a door) on the square the diagonal step would
    // leave open, and the game blocks that square like the part. A filler row has the copied part's mount, vpart,
    // hp_frac and other state bits, and its own (dx, dy, dz), which is no square of the vehicle's own parts. The
    // tiles' vehicle flag is set on fillers' squares too. None when the vehicle stands straight.

struct player_view {
    uint64 uid; ui_point pos; float facing_deg; int32 moves; uint32 move_mode;
    std::vector<uint32> body_parts;          // body_part indices (main parts); hp arrays follow this order
    std::vector<int16> hp, hp_max;
    int32 stamina, stamina_max;
    int16 hunger, thirst, sleepiness, pain, morale;
    uint32 wielded;
    std::vector<uint8> bleed, bandaged, disinfected, bite, infected;   // per body part, effect intensity (0 none)
    std::vector<worn_view> worn;             // inner to outer (CDDA's order), visible items only; cap 64
    std::vector<carried_view> items;         // wielded, then worn (CDDA's worn order), each followed by what's inside, depth first; cap 256, 8 levels
    std::vector<item_state_view> item_states;   // live item tiles (2026-11-17): what items show of their state; cap 512
    std::vector<item_amount_view> item_amounts;   // exact numbers (G2, 2026-11-17): every carried item, then those in reach; cap 1024
    optional<gun_view> wielded_gun;          // JSON "wielded_gun", only when the wielded item is a gun
    std::vector<effect_view> effects;        // what CDDA's @ screen lists (effects with no display name left out); cap 64
    mood_view mood;                          // CDDA's morale screen (2026-11-12)
    optional<activity_view> activity;        // JSON "activity", only while an activity runs (2026-11-17)
    bool asleep;                             // JSON "asleep": true, only with CDDA's sleep effect (2026-11-17)
    bool driving;                            // JSON "driving": true, only while the player holds a vehicle's controls (2026-11-19)
    uint64 vehicle;                          // JSON "vehicle": uid of the vehicle the player is boarded on (`vehicles[].uid`); left out when none (2026-11-19)
};
struct mood_view {
    int16 level;                             // CDDA's morale level, the same number as `morale`
    int8  band;                              // -3 .. 3 from `level`, by the steps of CDDA's default mood face:
                                             // >= 100: 3, >= 50: 2, >= 10: 1, >= -10: 0, >= -50: -1, >= -100: -2, lower: -3
    string face;                             // CDDA's mood face for this character and level, e.g. ":)", "D:"; up to 16 bytes
    uint16 total;                            // how many entries CDDA's morale screen lists (entries may hold fewer)
    std::vector<mood_entry> entries;         // the strongest first (largest |value|, then by name); cap 12
};
struct mood_entry { string name /* the morale screen's line, e.g. "Music", "Enjoyed honey"; color tags removed; up to 60 columns */;
                    int16 value /* its morale points now, decay and temper applied; signed, never 0 */;
                    uint8 percent /* its share of its side (good or bad), cut to a whole number as the morale screen shows it; 0..100 */; };
// The level is not the sum of the values: CDDA takes sqrt(sum of good values squared) - sqrt(sum of bad values squared),
// cut to a whole number, and scales it further while the character is on Prozac (a bad level times 0.25). Don't
// work the level out from the entries. An entry whose morale type the game data doesn't know (a save from other
// mods) has no name: it is counted in `total` and left out of `entries`.
// What the character is busy with, for a "time passes" line: while an activity runs or the character sleeps no
// request comes, and a snapshot comes about every 0.5 s of real time instead. Older bridges send neither field.
struct activity_view {
    std::string id;     // CDDA's activity type id, "ACT_WAIT": letters, digits and _ only, up to 64 bytes; "" if a
                        // mod's id is anything else
    std::string verb;   // CDDA's verb for it, "waiting": color tags removed, up to 40 columns; may be ""
};
// JSON: "activity":{"id":"ACT_WAIT","verb":"waiting"}. Lying down and trying to sleep is the activity
// ACT_TRY_SLEEP ("trying to fall asleep"), not `asleep` yet; asleep there is usually no activity.
// JSON: "mood":{"level":-20,"band":-1,"face":"):","total":2,"entries":[{"name":"Craving caffeine","value":-30,"percent":100},
//   {"name":"Music","value":10,"percent":100}]}
struct effect_view { string id /* effect_type id, e.g. drunk, bleed; up to 64 bytes */;
                     string name /* CDDA's display name for this intensity, color tags removed; up to 40 columns */;
                     uint32 body_part /* body_part index, 0 = whole body */; uint8 intensity;
                     int8 rating /* -1 bad, 0 neutral, 1 good, 2 mixed */; int32 seconds_left /* -1 permanent */; };
// JSON: "effects":[{"id":"stunned","name":"Stunned","body_part":0,"intensity":1,"rating":-1,"seconds_left":300}]
struct gun_view { uint32 type /* itype */; int16 dirt /* CDDA's fouling 0..10000; JSON: left out for a NON_FOULING gun */;
                  int32 rounds /* loaded rounds; JSON: left out for a gun that takes no ammo */;
                  std::vector<string> faults /* fault ids it has (jams: gun_mechanical_simple ones); cap 16, ids up to 64 bytes */;
                  bool suppressed /* a gunmod, built-in too, lowers its report (loudness_modifier < 0 or loudness_multiplier < 1,
                                     as item::gun_noise counts it); JSON: "suppressed":true after faults, left out when false */;
                  // Gun mods by hand (2026-11-17), always present on a bridge that has them:
                  std::vector<gun_mod_view> mods;    // what the gun has, CDDA's order, cap 16
                  std::vector<gun_slot_view> slots;  // its slots as they are now, cap 16
                  std::vector<gun_fit_view> fits;    // every carried gun mod that isn't in a gun, cap 32
                };
struct gun_mod_view  { uint64 uid; uint32 type; std::string location; uint8 flags; };
    // JSON row: [uid, type, location, flags]. uid: the mod's item handle, as the `mod_remove` item action takes it
    // (installed mods are not in the carried `items`). location: the id-table `gunmod_location` ("" if not plain).
    // flags: 1 = can't be taken off (CDDA's IRREMOVABLE; a gun's integral mods have it too).
struct gun_slot_view { std::string location; uint8 slots; uint8 free; };
    // JSON row: [location, slots, free]. The gun type's own slots plus those its installed mods add; slots
    // 1..16, free 0..slots; only kinds with a plain location id.
struct gun_fit_view  { uint64 uid; bool ok; uint8 chance; uint8 risk; std::string reason; };
    // JSON row: [uid, ok (0/1), chance, risk, reason]. uid: a carried gun mod as `items` lists it. ok: it would
    // go on now, as CDDA's install menu decides: the gun takes it, the character has the skills, and the chance
    // is above 0. chance, risk: CDDA's odds without tools in percent (100 and 0 for most mods); they follow the
    // character's focus, so they move over time. reason: CDDA's words when it doesn't fit, colour tags removed,
    // up to 80 bytes ("doesn't have a slot for this mod", "requires at least ...", "is too difficult for you to
    // modify"); "" when ok.
struct worn_view { uint32 type /* itype */; uint8 layer /* highest layer_level */; uint8 damage /* damage_level 0..5 */;
                   uint8 degradation /* 0..255 of max */; std::vector<uint32> covers /* body_part indices */; };
struct carried_view { uint64 uid; uint32 type; uint64 parent; int16 pocket; uint8 flags; };   // parent = container's uid (0 on the body); pocket = index into the parent's container pockets (as queue_item_action takes it), -1 on the body; flags: 1 worn, 2 wielded, 4 held in the off hand
struct item_state_view { uint64 uid; uint8 temp; int16 rot; int16 fill; uint32 fill_type; bool see_through;
                         int32 fill_ml; int16 dirt; };
    // One entry for a carried item (`items`), then for an item lying on the player's square or one of the 8 around it
    // (the handles the piles list there) and for what is directly inside such an item (`inside`). Sparse: an item
    // with nothing to show (temp 0, rot -1, fill -1, dirt -1) has no entry. uid = the item's handle.
    // temp: 0 normal, 1 hot, 2 cold, 3 frozen (CDDA's own HOT / COLD / FROZEN item flags).
    // rot: CDDA's relative rot in permille, 0..2000 (1000 = rotten); -1 = it doesn't rot. For a container: the
    // worst of what is directly inside it.
    // fill: permille of its CONTAINER pockets' capacity in use, 0..1000; -1 = it has no such pocket.
    // fill_type: itype index of the content with the largest volume, 0 = empty. see_through: one of those pockets
    // is of a see-through material (the game data's `transparent`: glass, clear plastic; an open pot is not). fill_ml: the volume inside in ml (clamped to int32); -1 = no such pocket.
    // dirt: a gun's fouling, 0..10000, the same unit as wielded_gun.dirt; -1 = not a gun, or one that doesn't foul.
    // A fouling that a save spells as anything but a number reads as 0.
    // JSON: player "item_states": [[uid, temp, rot, fill, fill_type, see_through (0/1), fill_ml, dirt], ...].
    // Older bridges send no "item_states": read a missing one as empty.
struct item_amount_view { uint64 uid; int32 count; int32 weight_g; int32 volume_ml; };
    // One entry for every carried item, in the order of `items`, then for every item lying on the player's square
    // or one of the 8 around it and for what is directly inside those (the same items `item_states` looks at, but
    // every one). uid = the item's handle.
    // count: its charges when CDDA counts it by charges (ammo, thread, liquids), else 1; 1..2^31-1.
    // weight_g: CDDA's weight of the item with everything in it; a stack: the whole stack. 0..1e9.
    // volume_ml: the room it takes where it is, as CDDA counts it: a rigid container (a bottle, a can) its own
    // size whether full or empty, a soft one (a bag) its own size plus what is in it; a stack: the whole stack.
    // 0..1e9. So a row shows its numbers as they are, and a pocket's fill is the sum over the items directly in
    // it; summing down the tree would count the contents of every container twice.
    // JSON: player "item_amounts": [[uid, count, weight_g, volume_ml], ...]. Older bridges send none: read a
    // missing one as empty and fall back to the item type's numbers.

struct environment_view {
    int64 turn_of_day_s; uint8 season; float sun_alt_deg, sun_az_deg; uint8 moon_phase;
    uint32 weather;               // weather index
    float temperature_c;          // air temperature on the player's square
    float wind_speed /* m/s, the region's wind */, wind_dir_deg /* compass degrees the wind comes from: 0 north, 90 east */;
    uint8 ambient_light;          // natural light level at the player's z
    // CDDA's weather in full (2026-11-12). What the current weather type does, so no table lookup is needed:
    string weather_id;            // weather_type id, e.g. "clear", "drizzle", "thunder", "snowstorm"; up to 64 bytes
    string weather_name;          // CDDA's name for it, e.g. "Thunder Storm"; up to 40 columns
    uint8 precip;                 // strength: 0 none, 1 very light, 2 light, 3 heavy (CDDA's precip_class)
    uint8 precip_kind;            // 0 none, 1 rain, 2 snow (what CDDA draws and sounds as snow: its snowflake
                                  // animation or a flurries / snow / snowstorm sound; anything else that falls is rain)
    uint8 weather_sound;          // CDDA's sound category: 0 silent, 1 drizzle, 2 rainy, 3 rainstorm, 4 thunder,
                                  // 5 flurries, 6 snowstorm, 7 snow, 8 portal storm, 9 clear, 10 sunny, 11 cloudy
    float sight_penalty;          // CDDA's sight cost factor per square in this weather: 1 none, rain 1.1, fog 1.7; 0..100
    int16 light_modifier;         // what this weather adds to natural light (clouds: negative); -1000..1000
    float sun_multiplier;         // how much of the sun gets through: 1 clear sky, cloudy 0.3, rain 0.03; 0..10
    int16 sound_attn;             // how much this weather drowns sounds (CDDA's sound_attn); 0..1000
    bool  dangerous;              // CDDA counts this weather as dangerous (it interrupts activities)
    // At the player:
    float wind_at_player;         // m/s on the player's square, as CDDA works it out: 0 when sheltered, less in a
                                  // forest or behind something that blocks wind, more higher up
    uint8 humidity;               // percent, 0..100, on the player's square (100 out in light or heavy rain)
    bool  sheltered;              // CDDA's is_sheltered: under a roof, underground or in a roofed vehicle; rain and
                                  // snow don't reach the player
};
// JSON adds to "env": "weather_id":"thunder","weather_name":"Thunder Storm","precip":3,"precip_kind":1,
//   "weather_sound":4,"sight_penalty":1.2,"light_modifier":-40,"sun_multiplier":0.01,"sound_attn":8,"dangerous":false,
//   "wind_at_player":3.1,"humidity":100,"sheltered":false
// Lightning is an event (events.md `lightning`), not a snapshot field: CDDA clears its flag before the turn ends.
// Older bridges send none of these keys: clients read a missing one as clear weather / no mood.
```

## Ids

- `ter`, `furn`, `trap`, `field`: CDDA's own int ids (index 0 = null), stable for the session.
- `itype`, `mtype`, `vpart`, `weather`, `body_part`, `move_mode` (and, for events, `damage_type`, `activity`,
  `sound`, `explosion`): session tables, index 0 = none (`fp3d::intern_id`, `id_names`). The id tables (block B6,
  [id_tables.md](id_tables.md)) pre-fill them sorted and define every id; `ids_generation` in each snapshot names
  the tables its indices belong to.
- `seq` and creature uids keep counting across `reset_snapshots` (a reload), so they are never reused in a session.

## Deltas

For a client that keeps the snapshot it parsed last and wants only what changed since. The snapshot object is as
above; only the JSON differs. `fp3d::write_client_snapshot_json` (bridge: `get_snapshot_delta_json(z_below,
z_above, since)`) writes the newest snapshot like `write_snapshot_json`, plus, right before `submaps`:

- `submap_keys`, always: `[[x, y, z, revision, detail_revision, hash], ...]`, one row for every submap of the
  levels asked for, in the snapshot's order, each position once. `hash` is the 32-bit FNV-1a (0..4294967295) of
  the bytes of that submap's object in `submaps` as the bridge wrote it. The client keeps the row with the
  submap it parsed; it need not compute the hash.
- `base`, only in a delta: the seq the delta is made against (the `since` asked with).
- `submaps`: in a full snapshot (no `base`) the object of every key row. In a delta only the objects whose bytes
  differ from the base's object at that position, or that the base has none for, and always the ones that hold
  the player's square or a square next to it, in this snapshot and in the base (at most 8).

Everything else (player, creatures, vehicles, env, `ids` for all the submaps of the levels) is whole every time.

`since` is the client's word and is only looked up. The bridge makes a delta only against a snapshot this call
wrote itself, one of the last 4 (`served_snapshots_kept`), written for the same levels, with the same
`bubble_origin` and the player on the same level. So a full snapshot comes on a fresh start, after a map shift,
on another level, for another range, after a reload, and for any `since` it doesn't know (0, made up, too old).

What the client checks (anything off: drop it and ask again with `since` 0, never a failed session):

- `base` is a whole number and equals the seq of the snapshot it holds;
- `submap_keys` has at most as many rows as a snapshot can have submaps, no position twice, every number in the
  range `submaps[].pos`, the revisions and a 32-bit value have;
- every object in `submaps` has a key row with its position and revisions, and goes through the same checks as
  in a full snapshot;
- a row without an object names a position the held snapshot has, with the same revisions and hash as the row
  that snapshot's object came with; a full snapshot has an object for every row.

A client that skips snapshots still loses nothing: a delta is always against the snapshot that client holds.
Checked by `fp3d-snapshot-test` ("client snapshot: ..."): a stand-in client puts each answer onto what it holds
and must end up with exactly `write_snapshot_json`'s text, over an unchanged snapshot, a changed submap, a step,
a change of light, an unknown, made-up and too old `since`, another range, a map shift, another level and a clear.

## Not yet in the snapshot

Facing and sub-tile offsets (block D1), worn items, animation state (events, block B4), per-part body
temperature, map memory contents (the client keeps what it last saw on remembered tiles).

## JSON (mock data)

`fp3d-headless <out.json> [z_below] [z_above]` writes a snapshot of a town with the same field names, submaps
limited to the z range, arrays as plain lists, items as `[tile, count, [top4]]` or `[tile, count, [top4], corpse_mtype, corpse_state]`,
item handles as a per-submap `handles` list of `[tile, uid, type, spot_x, spot_y]` (always five numbers), how placed items lie as a per-submap `poses` list of `[uid, yaw, side]` (only items with a stored pose: yaw whole degrees 0..359, side 0 or 1; the uid is one of that submap's handles; older bridges send no `poses`), the furniture shelf placed items were put on as a per-submap `shelves` list of `[uid, shelf]` (only items with a stored shelf, 0..15; older bridges send none), piles with more items than handles listed as a per-submap `more` list of `[tile, items not listed]` (L8; older bridges send none: count minus handles), what lies in containers on the player's square or one next to it (same level, items reachable there) as a per-submap `inside` list of `[container uid, uid, type, pocket]` (one level deep, container pockets only, never a sealed or forbidden one; `pocket` is the index item actions take; at most 64 per container and 256 per submap) and containers cut short as `inside_more` `[container uid, items left out]` (L8; older bridges send neither), carried items as the player's
`items` list of `[uid, type, parent, pocket, flags]` (both optional; the client checks ranges, caps, distinct uids
and that a container comes before its contents), fields as
`[tile, type, intensity, age]`, heat as a per-submap `heat` list of `[tile, source, tool, fire, charges, lit]` (lit 0/1), cookware as a per-submap `cookware` list of objects `{"tile", "uid", "type", "contents": [[uid, type, count], ...], "craft_result", "craft_recipe", "craft_progress"}` (craft fields always present: 0 / "" / 0 when none), lights as a per-submap `lights` list of `[tile, luminance, kind]` (always present, may be empty; cap 16). The client checks ranges and caps (32 heat, 16 cookware per submap, 16 contents), and that each cookware tile has a heat entry. Vehicle parts as `[mount_x, mount_y, vpart, hp_frac, state]`, plus
`ids_generation` and `ids`: the names of the CDDA ids used (`{"ter": {"12": "t_floor", ...}}`). Session tables and
all definitions are in the id tables JSON (4th argument). Mock: `mock/snapshot_town.json` with
`mock/id_tables.json`.

## Done-when (B3)

`fp3d-snapshot-test` checks every tile's ter/furn of all 2541 submaps against the submap buffer (`MAPBUFFER`, by
absolute submap: a different path from the bubble maths), before and after a map shift; plus sharing, revision
bumps, and creature uids.
