# Making 3D models for CDDA-3D

For anyone making models for the game. The game shows CDDA's world in 3D and VR. Each model stands for one CDDA
id (an item, a piece of furniture, terrain, a monster or a vehicle part). In VR, players pick models up, open
them, pour from them and cook with them, so models need a few named points besides the mesh.

Status: the client loads `.glb` models for furniture, traps, items and terrain (doors still use procedural
shapes; monsters and vehicle parts don't load models yet). Ids without a model show simple placeholder
shapes (PLAN.md H1, TASKS.md). A model that breaks the limits below is skipped with a warning in the
console, and the placeholder shows instead.

Art direction is still an open decision (PLAN.md: stylised low-poly or realistic). Agree on it with the project
owner before making many models, and keep one style across a set.

## The basics

- **Format:** glTF 2.0 binary (`.glb`), textures embedded.
- **Scale:** 1 unit = 1 metre, real-world size. Check the item's CDDA JSON: `longest_side` and `volume`
  should roughly match the model, because CDDA uses them to decide what fits in a pocket.
- **Axes:** Y up in glTF. In Blender: Z up, the front faces −Y (what you see in Front view, numpad 1), and
  the default glTF export (+Y Up) turns that into glTF +Z front. That is Godot's model front.
  - "Front" means the barrel, blade tip, spout or the side a drawer pulls out of.
- **Origin:** bottom centre. Items: resting the way they'd sit on a table. Furniture and terrain: on the floor,
  centred on the 1 m × 1 m tile.
- **Footprint:** CDDA furniture is one tile each, so a model fits inside 1 m × 1 m. Longer things, such as a
  row of counters, are several tiles with one model each, made so neighbours line up.
- **Terrain:** one tile, 1 m × 1 m, and 3 m high for walls (one storey). The game turns terrain models
  itself:
  - Walls, windows and fences: the wall runs left to right in Front view (along X). The front is one face
    of the wall; the game doesn't know inside from outside yet, so make both faces look right.
  - Stairs and ramps: the bottom step at the front, rising toward the back to 3 m. Longer flights repeat
    the model on each tile for now.
  - Floors, roofs and water: the whole tile surface; the model replaces the flat tile.
  - Trees, shrubs and other standing things: the game draws the ground under them, so model only the thing.
    Set `random_yaw` in the registry to turn them freely.
  - Doors stay procedural for now (the door leaf swings by hand).
- **Apply transforms** (scale 1, no rotation) before export.

## Budgets (PC VR at 90 fps, many items on screen)

| What | Triangles | Textures |
|---|---|---|
| Small items (cans, bottles, ammo, food) | up to 1,500 | 512 px |
| Hand tools, weapons, cookware | up to 5,000 | 1024 px |
| Large items, small furniture | up to 8,000 | 1024 px |
| Big furniture, vehicle parts | up to 15,000 | 2048 px |

- One material per model if possible, two at most.
- PBR metallic-roughness: base colour, normal, and occlusion-roughness-metallic packed in one texture.
- Transparency only for glass and liquids.
- No LODs needed for now (models are loaded at run time, so Godot doesn't make LODs; the budgets keep
  that fine).

**Hard limits** (the game refuses the file above these): 32 MB per file, 512 nodes, 60,000 triangles,
65,536 vertices per mesh primitive (one material of one mesh) and 250,000 in all, 128 markers, 32 drawn
meshes, 20 m on any side, 16 images of at most 4096 px a side and at most two 2048 x 2048 images' worth
of pixels in all (PNG or JPEG, embedded), 32 materials. Triangle meshes only; no animations, skins,
cameras or morph targets; extensions: KHR_texture_transform, KHR_materials_unlit,
KHR_materials_emissive_strength, KHR_mesh_quantization (and GODOT_single_root from Godot's exporter)
only. No external files: buffers and textures must
be inside the `.glb`, and the models folder must not contain links or junctions. All loaded models
together get 512 MB of decoded textures; past that, further textured models aren't loaded (warning).

## Named points (markers)

Markers are empties (Blender) or empty nodes, named exactly as below; numbered ones start at 1 (up to 99).
Blender's `.001` suffixes break the name, so rename duplicates. A model only needs the markers that apply
to it. Point markers that are meshes by mistake are hidden. Where a marker has a direction, "forward" means the model's front (−Y in
Blender) and "up" means Blender Z, unless it says otherwise.

**Held items**
- `grip`: the centre of the palm when held in the main hand. Forward = where the index finger points,
  up = the back of the hand.
- `grip_2`: the second hand for two-handed items (rifles, big pots, jerrycans).
- `muzzle`: guns, where the shot leaves. `mag_well`: where a magazine goes in. `sight`: the eye point for aiming.

**Containers (items and furniture)**
- `opening`: centre of the mouth or opening, up = out of it.
- `spout`: where liquid pours from (jerrycan, kettle, bottle).
- `fill`: a closed mesh of the inside space. The game hides it and draws the liquid inside it, cut at the
  fill level.
- `contents`: where solid contents sit (the bottom of a pot, a crate's floor).
- `lid`: the lid as its own mesh. Origin on the hinge, swinging around its local X axis. A lid with no hinge
  lifts off.
- `door_1`, `door_2`, …: cupboard and fridge doors as their own meshes. Origin on the hinge, swinging around
  the vertical axis.
- `drawer_1`, …: drawers as their own meshes, sliding forward.
- `handle_1`, …: the part a hand or the mouse grabs to open something (door handle, drawer pull, lid edge,
  knob), as its own mesh. It is a child of the door, drawer or lid it belongs to. The game highlights it when
  the crosshair or a VR hand is on it. Without one, the whole door, drawer or lid is grabbable.
- `surface_1`, …: flat planes where items lie, such as shelves, a drawer's floor or a table top. The plane's
  size is the usable area, and the game hides it. Items on the tile are spread over these planes in turn
  (item 1 on surface_1, item 2 on surface_2, ...); without any, they lie on the placeholder's surfaces.

**Doors, drawers and lids that open (furniture)**

On a furniture model, each `lid`, `door_N` and `drawer_N` is a part the player opens by dragging it (mouse or
VR hand). The game reads them like this:
- Everything under the marker moves with it: its own mesh, its child meshes (a door can be an empty on the
  hinge with the leaf as a child mesh), its `handle_N`, and any `surface_N` under it (a drawer's floor, the
  shelves on a fridge door), so items lying there move too. A door, drawer or lid inside another one moves
  with the outer one and doesn't open by itself.
- A door turns about the model's vertical line through the marker's origin, out toward the model's front:
  the game picks the direction that swings the middle of the door forward, so put the origin on the hinge
  edge (left or right) and the door opens the right way. Up to 110°.
- A lid turns about the marker's own X axis through its origin, lifting the side away from the hinge, up to
  100°. A door or lid whose middle is on its hinge line (origin in the middle) has no clear side: it opens
  as if hinged on the left (doors) or at the back (lids). Lift-off lids don't work on furniture yet.
- A drawer slides toward the model's front (Blender −Y), out by 80 % of its depth along that direction
  (at least 5 cm).
- The hand or mouse takes hold at the first `handle_N` inside it; without one, at the middle of the edge
  farthest from the hinge (doors, lids) or of the front face (drawers).
- At most 16 per model. Extra ones, and any whose meshes or handle reach more than 4 m from its origin,
  stay put with the rest of the model (warning in the console). Furniture on a roof doesn't open them.
- When CDDA has open and closed versions of the furniture (its `open` / `close` fields, e.g. `f_safe_c` and
  `f_safe_o`), dragging one far enough asks the game to open or close it; give both ids the same model.
  Other furniture's doors and drawers move in the client only.

**Cooking**
- `burner_1`, …: stove, hotplate and woodstove spots where a pot or pan sits.
- `knob_1`, …: knobs as their own meshes. Origin on the turning axis; knob N works burner N.
- `rack`, `spit`: grill rack and roasting-spit snap points (campfires, fireplaces, grills).
- `fire`: where flames start (burner, firebox, campfire).
- For food, make the raw and cooked versions (CDDA has separate ids, e.g. `meat` and `meat_cooked`) with the
  **same shape and UV layout**, so the game can blend between them while it cooks.

**Other**
- `light`: where a lamp's light comes from.
- Collision (optional): a simple child mesh named `<name>-convcolonly` (the game makes it a convex collider
  and hides it). Without one the game uses the bounding box.

## Monster hit regions

For the combat work. A monster model can mark where a shot hits which part of it:

- Make each region a simple child mesh named `hit_<weak point id>`, for example `hit_head` or `hit_leg`.
  Use CDDA's weak point ids from the monster's JSON (`weakpoints`). The ones the game knows today:
  `head`, `eye`, `abdomen`, `belly`, `arm`, `leg`, `hindleg`, `wing`.
- Humans and NPCs use CDDA's body part ids instead: `hit_head`, `hit_eyes`, `hit_mouth`, `hit_torso`,
  `hit_arm_l`, `hit_arm_r`, `hit_hand_l`, `hit_hand_r`, `hit_leg_l`, `hit_leg_r`, `hit_foot_l`, `hit_foot_r`.
- A region in several pieces gets a number per piece: `hit_leg_1`, `hit_leg_2` (rename Blender's `.001`
  suffixes, they break the name).
- The region is the mesh's box (its bounding box in its own space), so keep them simple boxes or low-poly
  hulls, and parent each to the bone or part that moves it.
- A `hit_` id the monster's JSON doesn't list counts as its body.
- The game hides these meshes and uses them as hit zones. A monster model without them uses the zones of
  its placeholder figure.
- The client doesn't read them yet. Adding them now saves redoing the model later.

## Weapons

For reloading by hand in VR. A gun model marks:

- `muzzle`: point marker at the end of the bore, its -Z along the bore.
- `grip`: point marker where the main hand holds it.
- `mag_well`: point marker where a magazine snaps in.
- `magazine`: the detachable magazine as its own mesh (part).
- `slide` or `bolt`: its own mesh, moving along +Z when racked.

The placeholder gun the game draws uses the same names.

## Files and the registry

- Put models under `assets/models/<kind>/<cdda_id>.glb`, where kind is `items`, `furniture`, `terrain`,
  `monsters` or `vehicle_parts`, e.g. `assets/models/items/pot.glb`, `assets/models/furniture/f_cupboard.glb`.
- Add an entry to a registry file in `assets/registry/` (format in `contracts/assets.md`):

```json
{ "type": "fp3d_model", "kind": "item", "id": "pot", "model": "items/pot.glb" }
```

- One model can serve several ids: `"id": ["pot", "pot_copper"]`. Ids that only differ by state (open and
  closed crate) go in `states`.
- A model made in neutral light grey can serve several ids by material. Each registry entry names its
  `material` (wood, brick, metal, ...), and the game tints the model's colours toward it (70 %), keeping
  the texture detail. Example: one `terrain/wall.glb` for `t_wall` (plaster) and `t_brick_wall` (brick):

```json
[
  { "type": "fp3d_model", "kind": "terrain", "id": "t_wall", "model": "terrain/wall.glb", "material": "plaster_white" },
  { "type": "fp3d_model", "kind": "terrain", "id": "t_brick_wall", "model": "terrain/wall.glb", "material": "brick" }
]
```

- Without `material`, the model shows its own colours. The material names are the list in
  `client/scripts/world/palette.gd` (`MATERIALS`).

## Good first models for the VR work

Cooking and looting are the next VR features (PLAN.md L8, L9), so these CDDA ids are the most useful first:

- **Cooking:** `pot`, `pan`, `f_oven` (kitchen stove), `f_woodstove`, `f_fireplace`, `meat` and
  `meat_cooked`.
- **Containers:** `jerrycan`, `bottle_plastic`, `can_beans`, `backpack`, `f_cupboard`, `f_dresser`,
  `f_fridge`, `f_counter`.
- **Tools:** `hose`, `knife_butcher`.

## Licence and credit

- The project is CC BY-SA 3.0 (`LICENSE.md`), so models must be shareable under it. Use your own work, or
  CC0 or CC BY sources with the credit written in a `LICENSE.md` next to the models.
- Nothing ripped from other games, and nothing from stores whose licence forbids sharing.
- If a model was made with an AI tool, name the tool in that `LICENSE.md` too.
- Keep personal details out of the files: real names, emails, and local paths in texture names.
- When committing, use your GitHub no-reply email in git (`git config user.email`), not a personal one.
