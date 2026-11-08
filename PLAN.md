# CDDA-3D — Master Plan

Goal: Cataclysm: Dark Days Ahead as a full 3D first-person game: free (sub-tile) movement, real Z-levels and a
friendlier UI, without losing CDDA's simulation depth, JSON content or mods.

## Core idea

Keep CDDA's C++ simulation as the authority and replace only the frontend.

```
[Godot 4 client]   render / input / UI / audio / client-side prediction
       ⇅  GDExtension (in-process C++, no IPC)
[bridge]           snapshots, events, actions, UI requests   <- the contract
       ⇅
[libcdda]          CDDA fork built headless (no SDL/curses), sim on its own thread
```

- **Why Godot 4:** open source (MIT), C++ GDExtension links CDDA directly, no royalties, and its scene/script
  files are text, so agents can read, diff and edit them. Unreal/Unity would work but are heavier and binary.
- **Why a sim thread:** CDDA calls blocking prompts (`query_yn`, `uilist`, `string_input_popup`, item pickers,
  target picker) from deep inside game logic. Running the sim on a worker thread and turning each blocking call
  into a request the client answers keeps *every* menu working on day one. Native UIs then replace them one by
  one.

## Decisions (defaults; change here, nowhere else)

| Topic | Default |
|---|---|
| Base | Latest CDDA **stable** tag, pinned; merge upstream once per stable release |
| Scale | 1 tile = 1.0 m, 1 z-level = 3.0 m (constants in one file) |
| Sub-tiles | 4×4 per tile (25 cm): collision, item placement, partial furniture |
| Time | Real-time, 1 turn (100 moves) = 1 s; pause, slow-mo, auto-pause on danger; classic turn mode kept as a toggle |
| Authority | Sim decides everything (hits, AI sight, damage); client renders and predicts only |
| Art fallback | model → `looks_like` chain → category generic → billboard from tileset sprite |
| Saves | Vanilla-compatible; new fields optional |
| Platforms | Windows first; Linux next (the VR tester runs Arch); macOS flat-screen only (no PC VR runtime there). The client is plain GDScript; only the bridge needs per-platform builds |
| Licence | CDDA is CC-BY-SA 3.0, so the project ships CC-BY-SA; assets must be CC0 / CC-BY / CC-BY-SA |
| VR | Optional mode (block L): PC VR through Godot OpenXR (SteamVR, Quest via Link/Air Link, Index, WMR); no standalone Quest (CDDA is a Windows DLL). VR is **always real-time**: pause and slow-mo stay, the classic turn toggle is off; optional motion time (L7) |

## Repo layout

```
cdda/        fork of CleverRaven/Cataclysm-DDA (submodule, branch fp3d)
bridge/      GDExtension: libcdda <-> Godot (C++)
client/      Godot project
contracts/   interface specs, JSON schemas, mock data shared by all blocks
assets/      models, textures, audio, registry JSON (+ LICENSE per pack)
tools/       coverage reports, mesh generation, test drivers
docs/        design notes
```

Upstream-diff rule: keep edits inside `cdda/` minimal, put new code under `cdda/src/fp3d/`, and mark every edit
to an upstream file with `// FP3D:` so merges stay cheap.

## Milestones

| M | Name | Playable result | Blocks |
|---|---|---|---|
| M0 | Toolchain | Fork builds on Windows, CDDA tests pass, Godot project loads the bridge | A |
| M1 | Ghost walk | Load a vanilla save, fly a camera through the reality bubble in 3D, all z-levels | B1, B3, B6, C1–C3 |
| M2 | Step | Classic turn-based play in 3D: smoothed walking, doors, pickup, every prompt via generic UI | B2, B4, C4, E1–E3 |
| M3 | Free | Continuous movement, real-time clock, melee and ranged in first person | D1–D4, F1–F3 |
| M4 | Up & down | Stairs, ramps, ladders, falls, climbing; multi-level view; vehicles and driving | C5, C7, D5–D7 |
| M5 | Friendly | Native HUD, inventory, crafting, construction, map, onboarding | G, E4 |
| M6 | Ship | Art for ≥90 % of spawn-weighted ids, audio, perf targets, release build | H, I, J, K |

Critical path: **A1 → B1 → B3 → C2 → B2 → D1 → F**. Everything else runs in parallel against `contracts/` with
mock data.

VR (block L) is off the critical path: L1 (look around the live world in a headset) can start after M1; the rest
needs M3 (real-time clock, free movement, first-person combat) and ships with M6.

## Contracts (write first; block B owns, every other block reviews)

| File | Content |
|---|---|
| `contracts/snapshot.md` | Read-only world view per turn: per submap + z, ter/furn/trap/fields/item summary with dirty flags; creatures, vehicles, player state, light levels, visibility and map memory |
| `contracts/events.md` | Sim → client: sound, attack, hit, projectile path, explosion, message, death, map changed |
| `contracts/actions.md` | Client → sim: move vector, look-at, interact(target), attack(target, aim), raw `action_id`, pause/timescale |
| `contracts/ui_requests.md` | Sim → client blocking prompts (yes/no, menu, text, number, item select, direction/target pick) and answers |
| `contracts/assets.md` | `fp3d_model` registry schema and fallback chain |

`contracts/mock/*.json` (dumped from a real save) lets C, G and H start before B is finished.

---

## Blocks

Each line: **ID — task.** Done-when. *(depends on)*

### A. Foundation — 1 agent
- **A1 — Fork and build.** Fork the latest stable tag; build with MSVC + vcpkg (`msvc-full-features`) and CMake;
  run `cata_test`. Done: tiles build runs, tests green.
- **A2 — Repo skeleton** per layout above: git init, `.gitignore` (no saves, builds, game data), submodule,
  `LICENSES/`. *(A1)*
- **A3 — CI** (GitHub Actions, Windows + Linux): build fork + bridge, run tests, export client. *(A2)*
- **A4 — Upstream playbook:** script to merge the next stable tag, list of `// FP3D:` edits, conflict notes.
- **A5 — Agent conventions:** branch per sub-block, TASKS.md/WORKLOG.md updates, contract-change process.

### B. Simulation core as a library ("libcdda") — 1–2 agents, C++
- **B1 — Headless target.** Build CDDA core without SDL/curses as a static lib (start from how `cata_test`
  links). Done: a test binary loads data + a save. *(A1)*
- **B2 — Step-able loop + sim thread.** Split `game::do_turn` / `handle_action` so the sim advances on a worker
  thread; route every blocking input/UI call (`input_context::handle_input`, `query_yn`, `uilist`,
  `string_input_popup`, inventory selectors, target picker, `popup`) through a `ui_request` channel. Done: a
  scripted client does "open door, pick up, eat" with no SDL/curses. **Hardest task — prototype in week 1.** *(B1)*
- **B3 — Snapshot API.** Copy the reality bubble (11×11 submaps × 21 z) into an immutable snapshot per turn;
  per-submap dirty flags; handle `map::shift`. Done: tile-for-tile match with CDDA's own view of a test save. *(B1)*
- **B4 — Event bus.** Hook `sounds::sound`, attacks, projectile paths, explosions, `add_msg`, and the `draw_*`
  animation calls into `contracts/events.md`. *(B1)*
- **B5 — Threading.** Double-buffered snapshot, action queue, clean handoff; ThreadSanitizer on Linux CI. *(B2, B3)*
- **B6 — Id tables.** Expose ter/furn/item/mon/vpart definitions (`looks_like`, colour, symbol, flags) to the
  client and asset tools. *(B1)*

### C. 3D world rendering — 2 agents (C-world: C1–C3, C7–C10; C-actors: C4–C6)
- **C1 — Coordinates.** One module mapping CDDA points (bubble/absolute) ↔ Godot space; origin rebasing on
  bubble shift. *(contracts)*
- **C2 — Terrain mesher.** Per submap per z: floors, walls with neighbour connections (`connect_groups` /
  `connects_to`), roofs, doors/windows (open/closed/broken), stairs, ramps, holes, open air. Rebuild dirty
  submaps only. Done: a town and a 3-storey building look right. *(C1, B3 or mock)*
- **C3 — Props.** Furniture, traps, item piles (N visible items at deterministic sub-tile offsets) via the asset
  registry + fallback chain. *(H1)*
- **C4 — Creatures.** Player/NPC/monster models, interpolation between sim positions, animation state machine
  (idle/walk/run/attack/hurt/die/crouch/prone) fed by events; billboard fallback. Render only creatures the sim
  says the player can see. *(B4)*
- **C5 — Vehicles.** Mesh from the parts grid, smooth rotation between CDDA facing steps, part damage states,
  doors, lights. *(C3)*
- **C6 — Atmosphere.** Sky/sun/moon from CDDA calendar and season; weather particles; CDDA lightmap → lamps and
  fires; fields (fire, smoke, gas, blood, acid) as particles/decals; darkness matching CDDA light levels.
- **C7 — Z-levels.** Show levels above/below, look down from roofs and through holes, vertical fog; cutaway for
  third-person/top camera.
- **C8 — Horizon.** Beyond the 132-tile bubble, low-poly impostors from overmap terrain (roads, forest, towns,
  water).
- **C9 — Cameras.** First person (default), over-the-shoulder, top-down/iso (for debugging and players who want
  it).
- **C10 — Performance.** LOD, culling, instancing; 60 fps at 1080p on a mid-range GPU.

### D. Movement, time and physics — 1–2 agents
- **D1 — Continuous position.** Player has a float position inside the bubble; sim owns it, client predicts and
  reconciles. Tile = floor(pos). Moves spent ∝ distance × CDDA move cost, so speed, encumbrance, terrain cost
  and stamina still matter. *(B2, B5)*
- **D2 — Sub-tile collision.** 4×4 occupancy from optional JSON `subtile_shape`; defaults from flags (walls full,
  thin furniture partial, flat none). Furniture height for vaulting and cover. *(J1)*
- **D3 — Real-time clock.** Turns tick by wall time with timescale; long activities (craft, read, sleep, wait)
  fast-forward like Project Zomboid; pause, auto-pause via CDDA safe-mode interrupts; classic turn toggle; a SUPERHOT-style mode (time runs
  while the player moves or acts, crawls when they stand still).
- **D4 — AI movement.** Keep CDDA tile pathfinding and AI; client smoothing/steering so creatures don't slide on
  a grid; tile snapping is an option (snap / smooth blend between squares, for the player and creatures);
  smooth paths need pathfinding that knows sub-tile shapes (D2). Keep "one creature per tile" in the sim until after M3.
- **D5 — Vertical movement.** Stairs/ladders/ramps as continuous traversal that triggers z-change; climbing
  (CDDA climb checks); falling → CDDA fall damage; walk/run/crouch/prone → camera height and hitbox; roof
  access.
- **D6 — Driving.** Analog steer/throttle → CDDA turn/accel; seat camera; collisions stay CDDA's. *(C5)*
- **D7 — Water and mounts.** Swimming, deep water, riding.

### E. Interaction and input — 1 agent
- **E1 — Input map.** Godot actions ↔ CDDA `action_id`; mouse look, WASD, gamepad, rebinding; command palette
  so every CDDA action stays reachable.
- **E2 — Look and interact.** Crosshair raycast → tile / furniture / item pile / vehicle part / creature; prompt
  "E: open, hold E: more" built from CDDA's examine/interaction options.
- **E3 — Generic UI-request renderer.** One Godot widget per `ui_request` type, mouse + keyboard. Gate for M2.
  *(B2)*
- **E4 — 3D placement.** Construction ghosts, zone painting, moving furniture, vehicle construction view.
- **E5 — Accessibility.** Text size, colour-blind palettes, FOV/motion options, hold vs toggle.

### F. Combat — 1 agent
- **F1 — Melee.** Hit what the crosshair/cone targets via CDDA melee; swing time = move cost; techniques;
  hit reactions. *(D1, E2)*
- **F2 — Ranged.** Free aim → target point with sub-tile offset; aim time and sway → CDDA dispersion; projectile
  drawn on the true 3D line from the muzzle, hit resolved by the sim; recoil, reload, throwing arcs, ammo HUD.
- **F3 — Feedback.** Body-part hit indicators, pain/stamina/bleeding screen effects, gore decals, sound.
- **F4 — Stealth.** Noise/visibility hints from CDDA sound and light values; sneaking.

### G. UI/UX — the "user friendly" part — 2 agents (G-hud: G1, G8; G-menus: G2–G7)
- **G1 — HUD.** Body-part health doll, stamina, hunger/thirst/fatigue/temperature icons, effects bar, filtered
  message feed.
- **G2 — Inventory.** Pockets/containers as nested panes with drag & drop, weight/volume bars, worn-gear paper
  doll by layer, hotbar, ground and nearby-containers panel.
- **G3 — Crafting.** Search, "craftable now" filter, missing requirements highlighted, nearby tools counted,
  batch and queue.
- **G4 — Character.** Skills, proficiencies, mutations, bionics, morale, effects as readable cards with tooltips.
- **G5 — Map.** Overmap viewer (2D first, 3D later), notes, routes, auto-travel.
- **G6 — Onboarding.** Guided start scenario, contextual hints, glossary tooltips.
- **G7 — Menus.** Main menu, world/character creation (wrapped via E3 first, native later), options.
- **G8 — Classic overlay.** Dev panel showing CDDA's own tiles/ASCII view of the same snapshot, for parity checks.

### H. Art and asset pipeline — 1–2 agents
- **H1 — Asset registry.** `fp3d_model` JSON keyed by ter/furn/item/mon/vpart id with the fallback chain;
  client loader. *(contracts)*
- **H2 — Coverage tool.** Ids without models, ranked by spawn frequency (mapgen + itemgroup weights). Decides
  what art gets made next. *(B6)*
- **H3 — Auto placeholders.** Walls/floors from tileset textures; billboards or extruded sprites for the rest
  (check the tileset's licence first).
- **H4 — Style guide + kits.** Modular building kit (walls, doors, windows, roofs, stairs), furniture, vehicle
  parts. CC0 sources (Kenney, Quaternius, Poly Haven) plus fal image→3D for gaps; LICENSE per pack.
- **H5 — Characters.** Base human + zombie variants, rig and animation set; clothing as layered generic meshes
  tinted by item colour/material.
- **H6 — Monster families.** By species/size (zombies, animals, mutants, robots, fungal, nether) with variants.

### I. Audio — 1 agent (can share with H)
- **I1 — Spatial audio** from sound events (volume, position, type); footsteps by terrain material.
- **I2 — Ambience:** weather, interior/exterior reverb, music by danger level.
- **I3 — Licensing:** reuse a compatible CDDA soundpack or new CC0 audio.

### J. Data and content extensions — 1 agent
- **J1 — New optional JSON fields:** `subtile_shape`, `height`, `fp3d_model`, with validation and flag-based
  defaults; vanilla mods need zero changes.
- **J2 — Mapgen/z check:** basements, multi-storey, roofs, rooftop access render and traverse correctly (fix
  data, not code, where possible).
- **J3 — Mod compatibility:** popular JSON mods load; missing art falls back cleanly.

### K. QA, performance, security, release — 1 agent, ongoing from M1
- **K1 — Determinism/parity:** same save + seed + action script ⇒ same sim result in classic and 3D modes.
- **K2 — Automated play tests:** scripted scenarios + screenshots; regression gallery.
- **K3 — Perf budgets:** sim < 10 ms per turn, 60 fps, memory ceiling; profiling reports.
- **K4 — Saves:** load/save both ways with vanilla CDDA.
- **K5 — Security:** treat saves, mods and downloaded content as hostile (bounds-check sizes and ids, no code
  from data); load DLLs only from the app directory; no secrets in the repo.
- **K6 — Release:** packaging, CC-BY-SA attribution, per-asset licences, changelog.

### L. VR — 1 agent; L1 after M1, L2–L7 after M3
PC VR only (Godot OpenXR). Always real-time (pause and slow-mo allowed, no turn mode). The sim stays the
authority: VR changes how the player gives actions, never how CDDA resolves them.
VR is meant to become the main way to play (user, 2026-11-07): picking things up and opening containers by hand
should be less clunky than CDDA's menus. VR-first rule: wherever CDDA asks through a menu (doors, items, containers, crafting,
construction, vehicles), VR should get a physical way to do it; each one needs a menu-free bridge action
for one given thing, which the flat screen can use too.
- **L1 — VR ghost walk.** OpenXR rig (`XROrigin3D`, `XRCamera3D`, two controllers) on the live world; teleport
  and smooth locomotion, snap/smooth turn, comfort vignette; no interaction yet. Proves 90 fps stereo on the
  bubble. *(C1–C3, B3)*
- **L2 — Hands.** Point or reach to pick a target, grip/trigger for E2's actions (open, examine, pick up, use);
  items in hand follow the controller; picking up and dropping map to CDDA actions. Analog doors (user,
  2026-11-07): grab the handle and swing the door by hand, any angle; the angle is the client's, CDDA's door
  stays open/closed: past a threshold the client queues `open`/`close` (CDDA's time cost). A door held ajar
  lets you peek into the room: CDDA's sight needs a rule for it (treat as open for sight from the doorway, or
  a narrow sight cone through the gap, a small fork change); NPCs/monsters may push it. Flat screen gets the
  same doors through mouse drag. *(E2, D2)*
  Physical item handling (user, 2026-11-07; the kind Half-Life: Alyx made common): items lie as physics
  objects where they fell (sub-tile positions are the client's, CDDA keeps them per square); grab one by hand,
  or point and pull it to the hand from nearby; hold, turn, hand it to the other hand; put it over the
  shoulder or at the hip to store it (CDDA puts it into a worn container: volume and weight limits stay
  CDDA's); let go to drop, throw with the release speed (CDDA `throw` with the target from the arc). Needs
  per-item handles in the bridge (snapshots only list the top 4 itypes of a pile) and pick-up/insert/drop
  of one given item without CDDA's menus; how far a pull may reach is a rules question (CDDA picks up only
  from adjacent squares). Details from the user and the VR tester (2026-11-07): pull = aim and press, or flick
  the wrist; the flying item stays tethered to the hand until caught (catch assist, the part that makes it
  feel good); held containers shouldn't tip or spill (more frustrating than fun); fill a container by dipping
  it into a water source, e.g. a jug into a sink (CDDA's fill from terrain/furniture liquid, no liquid
  simulation; sloshing at most as a shader); a quick switch per hand (take a given item from the inventory
  into a given hand); later, hand intent from finger pose (how the hand is held says what it is meant to do).
- **L3 — Aim and melee.** Point the weapon to aim (target from the controller ray, CDDA rolls the hit); a swing
  above a speed threshold starts a melee attack on what it touches, CDDA resolves it; hit feedback (haptics,
  sound, flinch) from events. *(F, B4)*
- **L4 — World-space UI.** E3 widgets and G's HUD on a wrist panel or a floating panel (`SubViewport` on a
  quad), laser-pointer input; text size readable in a headset. *(E3, G)*
- **L5 — Body and comfort.** Seated/standing, height calibration, crouch/prone from head height (D5), comfort
  options (vignette, snap turn, teleport only), left-handed mode. *(E5)*
- **L6 — VR performance.** 90 fps stereo: foveated rendering where the runtime offers it, culling and LOD,
  tighter frame budget than K3; no main-thread stalls. *(K3)*
- **L7 — Motion time (option).** Time flows with how much the player moves: still ≈ stopped, slow movement =
  slow time, normal movement = 1×. The client measures motion each frame (locomotion and hands count most, head
  turning little), maps it through a tunable curve and eases the bridge timescale over a fraction of a second.
  Needs the bridge's timescale floor lowered from 0.25 to ~0 and D4's creature smoothing (CDDA moves creatures
  in 1 s steps). Open design point: whether swings and reloads spend time as they happen or take effect at
  once. Also usable on a flat screen. Our own name for it, not another game's. *(D3, D4, L3)*

**VR-ready rules for every agent, from now on** (cheap now, expensive to retrofit):
- Gameplay input goes through E1's action map only; no hard-coded keys or mouse reads in game logic.
- UI widgets work inside a `SubViewport`: no reliance on screen size, the OS cursor or global mouse position.
- Nothing heavy on the main thread: snapshot parsing and meshing move to a worker thread; a frame hitch makes
  people sick in VR.
- The camera rig is separate from the player's body/sim position (head ≠ body), and the HUD is not drawn
  straight onto the screen in a way that can't move into world space.

---

## Agent waves

| Wave | Start when | Agents (blocks) |
|---|---|---|
| 1 | Now | A · B1 + B6 · contracts draft (B lead) · H1 + H2 |
| 2 | M0 done, mock snapshot exists | B2–B5 · C-world (C1–C3, C7) · E1 · G8 |
| 3 | M1 done | C-actors (C4–C6) · E2–E3 · D1–D3 · G1 · L1 |
| 4 | M2 done | D4–D7 · F · C5 · G2–G7 · H3–H6 · I |
| 5 | M3–M4 done | J · C8–C10 · K in full · E4–E5 · L2–L7 |

At most ~6 agents at once; one owner per directory; contract changes go through the B lead.

## Top risks

1. **Blocking UI calls throughout CDDA** → B2 sim thread + `ui_request` channel; prototype first.
2. **Real-time changes balance** (hordes, ranged) → timescale, pause, auto-pause, classic toggle; tune in playtests.
3. **Upstream churn** → pinned stable tag, small marked diff, merge per release.
4. **Thousands of ids need art** → fallback chain + coverage-ranked production.
5. **132-tile bubble limits view distance** → overmap impostors (C8); a bigger bubble only if perf allows.
6. **Licence** → CC-BY-SA covers the whole derivative; compatible assets only.
7. **VR comfort and frame rate** (motion sickness, 90 fps stereo) → comfort options, worker-thread snapshot
   work, L6 budgets; test in a headset early (L1).
8. **VR melee vs CDDA's dice** (a swing that visibly connects but misses) → CDDA still decides; clear miss/block
   feedback; tune in playtests.

## Open decisions for the user

- Engine: Godot 4 (default) / Unreal 5 / custom C++ renderer.
- Art direction: stylised low-poly (fast, consistent) / realistic (far more art).
- Default mode: real-time / turn-based (flat screen only; VR is always real-time).
- VR headset to test on (L1).
