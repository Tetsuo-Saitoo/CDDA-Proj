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
| `model` | `.glb` path relative to `assets/models/` (plain relative path: letters, digits, `_ - . /`, no `..`) |
| `mesher` | Terrain only: procedural builder (`floor`, `wall`, `window`, `door`, `fence`, `stairs_up`, `stairs_down`, `ramp`, `water`, `roof`, `open_air`) |
| `placeholder` | Props (furniture, traps, items): a procedural low-poly shape the client builds while there is no model (`chair`, `table`, `counter`, `shelf`, `bed`, `fridge`, `item_book`, ...; the list is `NAMES` in `client/scripts/world/prop_shapes.gd`) |
| `material` | Material name from `assets/materials/` (for now the palette names in `client/scripts/world/palette.gd`). Colours meshers and placeholders, and tints the entry's model (see Models) |
| `scale`, `offset`, `random_yaw` | Placement inside the tile (offset in metres, before sub-tile jitter) |
| `states` | Other CDDA ids that are the same object in another state (shares rig/animations) |
| `anim_set` | Monsters/NPCs: animation set name (`humanoid`, `quadruped`, `insect`, `blob`, …) |

## Fallback chain (client and coverage tool must agree)

Art means an entry the client can show for that kind: terrain needs a `mesher` or a `model` that loads,
everything else a `model` that loads or a `placeholder`. A model that is missing or fails the checks below
is skipped with a warning: the entry's placeholder (terrain: its mesher, else the shape from the flags)
takes over, and a model-only entry falls through to the next step.

1. Exact `id` in the registry, same `kind`.
2. CDDA `looks_like` of that id, then its `copy-from` parent; repeat (max 16 steps, stop on a cycle). Any kind
   counts here (a hedge looks like the terrain shrub). The client only has `looks_like` (id tables); the
   chain ends at an id its table doesn't define. Terrain follows `terrain` entries only, and stairs,
   ladders and ramps take a model here only from an id of their own kind (never a floor's).
3. Category generic: `generic_<kind>_<category>`, then `generic_<kind>`. Items by itype `category`;
   furniture by flags, first match of FLOWER→`flower`, SIGN→`sign`, CAN_SIT→`seat`, FLAT_SURF→`table`,
   CONTAINER→`container`, PLACE_ITEM→`shelf`; traps have no category. (Monsters by species + size later.)
   Generics live in `assets/registry/generic.json`. Terrain doesn't use step 3: the client derives its
   mesher from flags (`WALL`, `DOOR`, `WINDOW`, `GOES_UP`, ...), connect groups and open/close pairs.
4. Billboard of the tileset sprite (block H3).
5. Glyph card: the ASCII symbol in its CDDA colour on a floating card. Always available, so nothing is invisible.

`tools/coverage/coverage.py` reports which step each id lands on (steps 1-2), weighted by how often it spawns.

## Models (client)

The client loads `.glb` files at run time with Godot's `GLTFDocument` (`client/scripts/world/model_library.gd`),
not through Godot's importer: models live outside the Godot project and mods will ship their own. Models
are hostile input like the registry; a file is skipped (with a warning) when its path leaves
`assets/models/`, or it is over 32 MB, has more than 512 nodes, 60,000 triangles, 128 markers, 16 images,
32 materials, 64 animations or 8 skins, an image over 4096 px, or anything but embedded PNG/JPEG images and
embedded buffers (no external files), node cycles, or extensions it would need that the client doesn't
allow. The checks run on the glTF JSON before Godot parses anything; results are cached per path.

Each model's named points (docs/MODELS.md) are read into a small info that other code queries
(`ModelLibrary.Model`: `markers` name -> transform, `marker_parts` for moving parts, `surfaces`, `fill`,
`colliders`). Drawn: every mesh except point markers (`grip`, `spout`, `burner_N`, ... drawn as a mesh by
mistake), `surface_N`, `fill` and `*-convcolonly`. Moving parts (`lid`, `door_N`, `drawer_N`, `handle_N`,
`knob_N`) are drawn in their rest pose for now. Models face +Z; the client turns them so that +Z faces
where a placeholder's front would. Furniture, item and terrain models are drawn as one multimesh per model
part per submap.

An entry with both `model` and a palette `material` draws a tinted copy of the model: every material's
albedo colour is multiplied by lerp(white, material colour, 0.7), so textures keep their detail. A model
made in neutral light grey can serve several ids by material. The copy is made once per model and
material, at most 512 copies (past that, models are drawn untinted, with a warning); an entry without
`material` (or with a name that isn't a palette material) draws the model as
made.

## Placement (client, block C3)

Props stand at the tile centre plus `offset`, scaled by `scale`. Facing in 90° steps, from the neighbours
(CDDA sends no per-tile rotation): joined tiles (same id or connect groups) face together. A straight run of
row furniture (counters, shelves, benches, sofas...) faces across the run; a bed or bathtub block faces along
itself with the head at the wall, split into beds 2 long and 1-2 wide; other blocks share one facing. The
score favours the prop's `rotates_to` groups, seats toward a FLAT_SURF neighbour, the front onto walkable floor
and the back to a wall; ties go by a hash of the piece. Runs past 12 tiles and blocks past 24 face tile by tile.
Placeholder shapes draw joined tiles as one piece; models are still one per tile. `random_yaw` turns a prop
freely (hash of the square, so it never changes between rebuilds) and never joins.
Item piles show up to 8 items (the snapshot's top 4 by volume, then small clutter) on 4 × 4 sub-tile slots
picked by a hash of the square, sized by volume (models keep their real size), on the surfaces of the tile's
furniture (tables, shelves; a furniture model's `surface_N` planes when it has them, with the slots spread
over each plane); items in closed containers (fridges, dressers, crates) aren't shown unless the furniture's
model has surfaces (then its doors hide them).

Terrain models replace the tile's procedural shape. They stand at the tile centre on its floor (roof
terrain: lifted like its slab, and hidden with the roofs), plus `offset`, scaled by `scale`. Facing: walls,
windows and fences run along the model's X axis (+Z out of the wall: south for an east-west run, east for
a north-south one); stairs and ramps have the bottom step at the front and rise toward the back, along the
flight; anything else keeps the model's own orientation (+Z south), or turns freely with `random_yaw`.
Floor, roof and water models replace the slab; trees, shrubs, ladders, fences and other standing things
keep the ground slab under them. Doors, open air and the holes stairs come up through stay procedural (a
door leaf is a grabbable node; door models come later).
