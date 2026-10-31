# Asset registry: `fp3d_model` (block H1)

Maps CDDA ids to 3D art. Lives in `assets/registry/**/*.json`, same style as CDDA JSON (a list of objects).
Schema: [schema/fp3d_model.schema.json](schema/fp3d_model.schema.json). Mods can ship their own registry files.

```json
[
  { "type": "fp3d_model", "id": "f_chair", "kind": "furniture",
    "model": "furniture/chair_wood.glb", "scale": 1.0, "offset": [0, 0, 0], "random_yaw": true },
  { "type": "fp3d_model", "id": ["t_wall", "t_wall_w"], "kind": "terrain",
    "mesher": "wall", "material": "plaster_white" },
  { "type": "fp3d_model", "id": "t_door_c", "kind": "terrain", "mesher": "door",
    "model": "terrain/door_wood.glb", "states": { "open": "t_door_o", "broken": "t_door_b" } }
]
```

| Field | Meaning |
|---|---|
| `id` | CDDA id or list of ids sharing this art |
| `kind` | `terrain` \| `furniture` \| `trap` \| `field` \| `item` \| `monster` \| `vehicle_part` |
| `model` | `.glb` path relative to `assets/models/` |
| `mesher` | Terrain only: procedural builder (`floor`, `wall`, `window`, `door`, `fence`, `stairs_up`, `stairs_down`, `ramp`, `water`, `roof`, `open_air`) |
| `material` | Material name from `assets/materials/` (used by meshers and as tint for models) |
| `scale`, `offset`, `random_yaw` | Placement inside the tile (offset in metres, before sub-tile jitter) |
| `states` | Other CDDA ids that are the same object in another state (shares rig/animations) |
| `anim_set` | Monsters/NPCs: animation set name (`humanoid`, `quadruped`, `insect`, `blob`, …) |

## Fallback chain (client and coverage tool must agree)

1. Exact `id` in the registry.
2. CDDA `looks_like` of that id, then its `copy-from` parent; repeat (max 16 steps, stop on a cycle).
3. Category generic: `generic_<kind>_<category>` (items by category, monsters by species + size, terrain by
   flags such as `WALL`, `DOOR`, `FLAT`, furniture by `CONTAINER`/`SEAT`/…).
4. Billboard of the tileset sprite (block H3).
5. Glyph card: the ASCII symbol in its CDDA colour on a floating card. Always available, so nothing is invisible.

`tools/coverage/coverage.py` reports which step each id lands on, weighted by how often it spawns.
