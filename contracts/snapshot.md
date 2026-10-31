# Snapshot (sim → client)

An immutable copy of the reality bubble, produced by the sim thread at the end of every turn and after every
player action, then handed to the client (double-buffered, block B5). The client always reads the newest one.

Source in CDDA: `map` (`map_scale_constants.h`: `SEEX = 12`, `MAPSIZE = 11`, z from `-OVERMAP_DEPTH` (-10) to
`OVERMAP_HEIGHT` (10)), `avatar`, `creature_tracker`, `map::get_vehicles`, lightmap/seen caches, `weather_manager`,
`calendar`.

```cpp
struct Snapshot {
    uint32 contract_version;
    int64  turn;                 // calendar::turn, 1 turn = 1 s
    uint64 seq;                  // increments with every snapshot (several per turn possible)
    tripoint_abs_sm bubble_origin;   // absolute submap at bubble (0,0,z)
    PlayerView player;
    std::vector<SubmapView>   submaps;    // full: all 11*11*21; delta: only revision-changed ones
    std::vector<CreatureView> creatures;  // only those the player perceives      (cap 1024)
    std::vector<VehicleView>  vehicles;   //                                        (cap 256)
    Environment env;
    bool is_delta;               // client must keep previous SubmapViews and replace by pos
};

struct SubmapView {
    tripoint_abs_sm pos;
    uint32 revision;             // bumps on any change in this submap (ter, furn, items, fields, traps)
    TileView tiles[12 * 12];     // index = y * 12 + x
    std::vector<ItemPileView> items;   // sparse                                  (cap 144)
    std::vector<FieldView>    fields;  // sparse                                  (cap 144 * 4)
};

struct TileView {
    uint32 ter, furn, trap;      // id indices (0 = none / t_null)
    uint8  light;                // CDDA light level at the tile, quantised 0..255
    uint8  vis;                  // 0 never seen, 1 remembered, 2 seen now (lit), 3 seen now (dark)
    uint8  flags;                // bit0 has_roof, bit1 open_air below, bit2 graffiti/sign, bit3 has vehicle part
};

struct ItemPileView {            // only for tiles with vis >= 1
    uint8  tile;                 // 0..143
    uint16 count;                // total items on the tile
    uint32 top[4];               // itype indices of the 4 most visible items (largest volume first)
};

struct FieldView { uint8 tile; uint32 type; uint8 intensity; uint16 age_turns; };

struct CreatureView {
    uint64 uid;                  // stable across turns (monster/NPC/player)
    uint8  kind;                 // 0 player, 1 npc, 2 monster
    uint32 type;                 // mtype index (monsters) or 0
    tripoint_abs_ms pos;
    vec3f  subtile;              // offset inside the tile in metres (0 until block D1)
    float  facing_deg;           // 0 = north, clockwise
    uint8  move_mode;            // walk/run/crouch/prone (move_mode_type)
    uint8  hp_frac;              // 0..255 for health bars
    uint32 anim_state;           // idle/walk/attack/hurt/dead/... (events drive one-shots)
    std::vector<uint32> worn;    // NPC/player only: itype indices of visible worn items  (cap 64)
    uint32 wielded;              // itype index or 0
};

struct VehicleView {
    uint64 uid;
    tripoint_abs_ms pivot;
    float  face_deg, turn_deg;   // current facing and the facing it is turning to
    float  velocity;             // m/s
    std::vector<VehiclePartView> parts;                                         // (cap 4096)
};
struct VehiclePartView { point mount; uint32 vpart; uint8 hp_frac; uint8 state; /* bit0 open, bit1 broken, bit2 lit */ };

struct PlayerView {
    uint64 uid; tripoint_abs_ms pos; vec3f subtile; float facing_deg; float look_pitch_deg;
    int32 moves;                 // remaining move points this turn
    uint8 move_mode;
    // HUD data; block G may extend with more fields
    int16 hp[12];                // per body part, in body_part order from ids.md
    int16 hp_max[12];
    int32 stamina, stamina_max;
    int16 hunger, thirst, sleepiness, pain, morale, body_temp;
    uint32 wielded;
};

struct Environment {
    int64 turn_of_day_s; uint8 season; float sun_alt_deg, sun_az_deg, moon_phase;
    uint32 weather;              // weather_type index
    float temperature_c, wind_speed, wind_dir_deg;
    uint8 ambient_light;         // CDDA natural light level 0..255
};
```

## Done-when (B3)
A test binary dumps a snapshot of a known save to JSON (`mock/`), and a checker confirms that every tile's
ter/furn id matches what CDDA's own `map::ter()`/`map::furn()` return for the same absolute point.
