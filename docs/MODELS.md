# Making 3D models for CDDA-3D

For anyone making models for the game. The game shows CDDA's world in 3D and VR. Each model stands for one CDDA
id (an item, a piece of furniture, terrain, a monster or a vehicle part). In VR, players pick models up, open
them, pour from them and cook with them, so models need a few named points besides the mesh.

Status: the client doesn't load `.glb` models yet. Until it does it shows simple placeholder shapes (PLAN.md H1,
TASKS.md). Models made to this spec will show up without changes once loading lands.

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
- No LODs needed: Godot makes them on import.

## Named points (markers)

Markers are empties (Blender) or empty nodes, named exactly as below; numbered ones start at 1. A model only
needs the markers that apply to it. Where a marker has a direction, "forward" means the model's front (−Y in
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
  size is the usable area, and the game hides it.

**Cooking**
- `burner_1`, …: stove, hotplate and woodstove spots where a pot or pan sits.
- `knob_1`, …: knobs as their own meshes. Origin on the turning axis; knob N works burner N.
- `rack`, `spit`: grill rack and roasting-spit snap points (campfires, fireplaces, grills).
- `fire`: where flames start (burner, firebox, campfire).
- For food, make the raw and cooked versions (CDDA has separate ids, e.g. `meat` and `meat_cooked`) with the
  **same shape and UV layout**, so the game can blend between them while it cooks.

**Other**
- `light`: where a lamp's light comes from.
- Collision (optional): a simple child mesh named `<name>-convcolonly` (Godot makes it a convex collider and
  hides it). Without one the game uses the bounding box.

## Files and the registry

- Put models under `assets/models/<kind>/<cdda_id>.glb`, where kind is `items`, `furniture`, `terrain`,
  `monsters` or `vehicle_parts`, e.g. `assets/models/items/pot.glb`, `assets/models/furniture/f_cupboard.glb`.
- Add an entry to a registry file in `assets/registry/` (format in `contracts/assets.md`):

```json
{ "type": "fp3d_model", "kind": "item", "id": "pot", "model": "items/pot.glb" }
```

- One model can serve several ids: `"id": ["pot", "pot_copper"]`. Ids that only differ by state (open and
  closed crate) go in `states`.

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
