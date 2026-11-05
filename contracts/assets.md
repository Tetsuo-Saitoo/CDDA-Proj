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
| `placeholder` | Props (furniture, traps, items): a procedural low-poly shape the client builds while there is no model (`chair`, `table`, `counter`, `shelf`, `bed`, `fridge`, `item_book`, ...; the list is `NAMES` in `client/scripts/world/prop_shapes.gd`) |
| `material` | Material name from `assets/materials/` (used by meshers and as tint for models) |
| `scale`, `offset`, `random_yaw` | Placement inside the tile (offset in metres, before sub-tile jitter) |
| `states` | Other CDDA ids that are the same object in another state (shares rig/animations) |
| `anim_set` | Monsters/NPCs: animation set name (`humanoid`, `quadruped`, `insect`, `blob`, …) |

## Fallback chain (client and coverage tool must agree)

Art means an entry the client can show for that kind: terrain needs `mesher` or `model`, everything else
`placeholder` or `model` (models aren't loaded yet; until they are, a model-only entry falls through).

1. Exact `id` in the registry, same `kind`.
2. CDDA `looks_like` of that id, then its `copy-from` parent; repeat (max 16 steps, stop on a cycle). Any kind
   counts here (a hedge looks like the terrain shrub). The client only has `looks_like` (id tables); the
   chain ends at an id its table doesn't define.
3. Category generic: `generic_<kind>_<category>`, then `generic_<kind>`. Items by itype `category`;
   furniture by flags, first match of FLOWER→`flower`, SIGN→`sign`, CAN_SIT→`seat`, FLAT_SURF→`table`,
   CONTAINER→`container`, PLACE_ITEM→`shelf`; traps have no category. (Monsters by species + size later.)
   Generics live in `assets/registry/generic.json`. Terrain doesn't use step 3: the client derives its
   mesher from flags (`WALL`, `DOOR`, `WINDOW`, `GOES_UP`, ...), connect groups and open/close pairs.
4. Billboard of the tileset sprite (block H3).
5. Glyph card: the ASCII symbol in its CDDA colour on a floating card. Always available, so nothing is invisible.

`tools/coverage/coverage.py` reports which step each id lands on (steps 1-2), weighted by how often it spawns.

## Placement (client, block C3)

Props stand at the tile centre plus `offset`, scaled by `scale`. Facing in 90° steps: toward a neighbour in
the prop's `rotates_to` groups, seats with ALIGN_WORKBENCH toward a FLAT_SURF neighbour, anything else with
its back to a wall; `random_yaw` turns it freely (hash of the square, so it never changes between rebuilds).
Item piles show up to 8 items (the snapshot's top 4 by volume, then small clutter) on 4 × 4 sub-tile slots
picked by a hash of the square, sized by volume, on the surfaces of the tile's furniture (tables, shelves);
items in closed containers (fridges, dressers, crates) aren't shown.
