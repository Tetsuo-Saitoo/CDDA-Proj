# Id tables (sim → client, once per world)

What the ids in snapshots and events stand for: names, classic symbols and colours, `looks_like` chains for model
lookup, and the rules the mesher needs (flags, connect groups, open/close pairs). Implemented in
`cdda/src/fp3d/id_tables.h` (block B6). Built on the sim thread after a world's data loads (`fp3d::boot_world`
does it); the client reads `latest_id_tables()` (a `shared_ptr<const id_tables>`), or the JSON.

**Generation.** Every build bumps `generation`; each snapshot carries the `ids_generation` its indices belong to.
On a change the client drops everything it cached by index. Building also forgets the snapshot state (revisions,
uid map), so the next snapshot starts over.

**Stable session indices.** Building empties the session tables and refills `itype`, `mtype`, `vpart`,
`weather`, `body_part`, `move_mode` and `damage_type` with every id CDDA has, sorted. The same data (game version
and mods) gives the same indices every session, so a client or tool can cache by index. `activity`, `sound` and
`explosion` stay first-come (events add to them); an id CDDA creates later is appended.

| Table | Index | Fields |
|---|---|---|
| `ter`, `furn` | CDDA int id (0 = t_null / f_null) | id, name, symbol, color, looks_like, move_cost (ter: 0 = impassable; furn: modifier, -1 = impassable), coverage, light_emitted, transparent, flags, connect_groups, connects_to, rotates_to, open, close, roof (ter only) |
| `trap` | CDDA int id (0 = tr_null) | id, name, symbol, color |
| `field` | CDDA int id (0 = fd_null) | id, looks_like, priority, level_names, level_colors (per intensity, 1 = index 0) |
| `itype` | session index (0 = none, empty) | id, name, symbol, color, looks_like, category, volume_ml, weight_g, gun (guns only: the skill it uses, e.g. pistol, rifle, shotgun, smg, archery, launcher), gun_ammo (guns only: first ammo type, e.g. 9mm, 223, shot) |
| `mtype` | session index | id, name, symbol, color, looks_like, size (CDDA's creature_size: 1 tiny, 2 small, 3 medium, 4 large, 5 huge), hp, speed (100 = human), volume_ml, weight_g, species, bodytype (CDDA's body type: human, dog, insect, snake, bird, fish, blob, ...; may be empty), weakpoints (weak point ids: head, eye, arm, leg, ...; cap 32) |
| `vpart` | session index | id, name, color, looks_like, location, flags |

Symbols are UTF-8; CDDA's line-drawing pseudo symbols (walls) come out as "". Colours are CDDA colour names
(`c_light_gray`). Names are translated text from the game data (or mods): show them as plain text, never markup.

## JSON

`fp3d-headless <snapshot.json> [z_below] [z_above] <ids.json>` writes the tables as one object: `generation`,
`ter`, `furn`, `trap`, `field`, `itype`, `mtype`, `vpart` (arrays of objects with the fields above, by index), and
`tables` (every session table's names, by index). Mock: `mock/id_tables.json` (~2.7 MB, same generation as
`mock/snapshot_town.json`).

## Done-when (B6)

`fp3d-ids-test`: table sizes match CDDA's factories with null at 0, `t_wall` joins walls, door open/close pairs,
session tables sorted and identical after a rebuild (next generation), every id in a town snapshot resolves, and
the JSON parses back with the same sizes.
