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
    std::vector<shared_ptr<const submap_view>> submaps;   // all 2541, z -10..10 (JSON: top-level "z_levels": [-10, 10])
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
                        std::vector<item_handle_view> handles; };   // the first 32 items, CDDA's stack order
struct item_handle_view { uint64 uid; uint32 type; int16 spot_x, spot_y; };   // uid 1..2^53-1 (bridge_api.md "Single items"); type = itype index; spot = where it was placed, permille of the square (x east, y south), -1 none
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
    // cap 16. An in-progress CDDA craft among the contents: craft_result = itype index of the result (0 none),
    // craft_recipe = recipe id ("" none), craft_progress = permille.
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
};

struct vehicle_view {
    uint64 uid; ui_point pos;     // absolute square of the vehicle's position
    float face_deg, turn_deg;     // facing and the facing it is turning to
    float velocity;               // m/s
    string name;
    std::vector<vehicle_part_view> parts;   // cap 4096
};
struct vehicle_part_view { int mount_x, mount_y; uint32 vpart; uint8 hp_frac; uint8 state; /* bit0 open, bit1 broken, bit2 enabled */ };

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
    optional<gun_view> wielded_gun;          // JSON "wielded_gun", only when the wielded item is a gun
};
struct gun_view { uint32 type /* itype */; int16 dirt /* CDDA's fouling 0..10000; JSON: left out for a NON_FOULING gun */;
                  int32 rounds /* loaded rounds; JSON: left out for a gun that takes no ammo */;
                  std::vector<string> faults /* fault ids it has (jams: gun_mechanical_simple ones); cap 16, ids up to 64 bytes */; };
struct worn_view { uint32 type /* itype */; uint8 layer /* highest layer_level */; uint8 damage /* damage_level 0..5 */;
                   uint8 degradation /* 0..255 of max */; std::vector<uint32> covers /* body_part indices */; };
struct carried_view { uint64 uid; uint32 type; uint64 parent; int16 pocket; uint8 flags; };   // parent = container's uid (0 on the body); pocket = index into the parent's container pockets (as queue_item_action takes it), -1 on the body; flags: 1 worn, 2 wielded, 4 held in the off hand

struct environment_view {
    int64 turn_of_day_s; uint8 season; float sun_alt_deg, sun_az_deg; uint8 moon_phase;
    uint32 weather;               // weather index
    float temperature_c, wind_speed /* m/s */, wind_dir_deg;
    uint8 ambient_light;          // natural light level at the player's z
};
```

## Ids

- `ter`, `furn`, `trap`, `field`: CDDA's own int ids (index 0 = null), stable for the session.
- `itype`, `mtype`, `vpart`, `weather`, `body_part`, `move_mode` (and, for events, `damage_type`, `activity`,
  `sound`, `explosion`): session tables, index 0 = none (`fp3d::intern_id`, `id_names`). The id tables (block B6,
  [id_tables.md](id_tables.md)) pre-fill them sorted and define every id; `ids_generation` in each snapshot names
  the tables its indices belong to.
- `seq` and creature uids keep counting across `reset_snapshots` (a reload), so they are never reused in a session.

## Not yet in the snapshot

Facing and sub-tile offsets (block D1), worn items, animation state (events, block B4), per-part body
temperature, map memory contents (the client keeps what it last saw on remembered tiles).

## JSON (mock data)

`fp3d-headless <out.json> [z_below] [z_above]` writes a snapshot of a town with the same field names, submaps
limited to the z range, arrays as plain lists, items as `[tile, count, [top4]]` or `[tile, count, [top4], corpse_mtype, corpse_state]`,
item handles as a per-submap `handles` list of `[tile, uid, type, spot_x, spot_y]`, carried items as the player's
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
