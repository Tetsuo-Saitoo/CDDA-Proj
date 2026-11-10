# Taller buildings (2026-11-09)

Today's limit: `OVERMAP_DEPTH = OVERMAP_HEIGHT = 10` in `cdda/src/map_scale_constants.h`, so 21 layers
(z -10..10). The reality bubble (`MAPSIZE` 11 submaps) is 132 x 132 tiles on every layer.

## Tried: OVERMAP_HEIGHT 10 -> 30 (41 layers)
Built in a worktree (cdda branch `fp3d-tall`, not committed). Changes needed to run at all:
- the constant;
- `default_oter` in every region settings file (8: core and 7 mods), padded with 20 `open_air`
  (fixed-size `std::array<oter_str_id, OVERMAP_LAYERS>` read from JSON);
- `fp3d/sim_test.cpp` expected exactly `2541` submaps (= 121 x 21): now `121 * OVERMAP_LAYERS`.

Nothing else broke: it compiles, `fp3d-sim-test` 8/8, client `run_tests.gd` and `live_test.gd` (save,
then load in a second run) all pass with the z-30 bridge DLL. The player stayed at z 0, so the client's
hard-coded `CddaCoords.Z_MIN/Z_MAX = ±10` (`client/scripts/world/coords.gd`; snapshot validation rejects
other z) was not hit; it must take the range from the bridge before anyone climbs past z 10.

Not tested: old saves. Overmap files store one array per layer by position (`savegame.cpp` ~982-1250,
no z tag), so a 21-layer save in a 41-layer build runs out of arrays; changing DEPTH would shift all layers.
Old saves break unless the overmap file gets a z-range header and missing layers are default-filled.

### Measured (fp3d-sim-test, same code, RelWithDebInfo, 2 runs each, player at z 0, town start)
| | z 10 (21 layers) | z 30 (41 layers) | change |
|---|---|---|---|
| Max private memory | 1376 / 1376 MB | 1614 / 1430 MB | +54..238 MB (2nd run +4 %) |
| 5 actions (door, pick up, eat, look, throw) | 2.18 / 2.34 s | 3.81 / 3.07 s | ~ +50 % |
| Wait 5 min = 300 turns | 685 / 733 ms (~2.4 ms/turn) | 1000 / 899 ms (~3.2 ms/turn) | ~ +35 % |
| Save folder after the test | | 0.9 MB | small: empty layers compress to runs |

The "real time + auto-pause" goal is timing-flaky in both builds (failed once in each, unrelated).
So: memory is fine, but **turn time grows with every layer even when it is empty sky**, because
`build_map_cache`, light, vision, `get_inter_level_visibility` and vehicle caches loop over all z and
`level_cache` (~0.75 MB per layer: lightmap, seen, transparency... ~43 B/tile) exists for every layer.
Open air itself is cheap (uniform submaps: one terrain, no arrays).

## Project Zomboid (main reference)
PZ is the closest model for what we want (tile-based sim, first-hand building exploration).
- **B41: 8 floors (0-7).** B42 lifted it to **32 floors up and 32 down** (basements), and the height is
  **flexible per chunk**: each chunk stores only the levels it actually has, so empty sky costs nothing.
  This is the key idea: sparse levels, not a bigger dense array.
- **Streaming:** chunks (and their levels) load around the player; basements are prefab "buildings"
  dropped in when an area is first streamed. Far floors aren't simulated in detail.
- **Rendering / cutaways:** floors above the player are hidden or faded when you are inside; walls near
  the camera cut away. Only the player's floor and below are drawn in full near you; the skyline is drawn
  from the same data at distance.
- **Cost:** a community guide claims B42's visibility work over 32 floors roughly quadruples active-chunk
  memory vs B41 (unofficial, not verified). Even PZ pays for it, which fits our measurement.
Sources: projectzomboid.com blog (Build 42 posts), NME article on basements, supercraft.host B42 guides
(the last two secondary).

## What to do (recommended, PZ-style)
1. **Client z range from the bridge** (no hard-coded ±10). Cheap; do it first.
2. **Versioned overmap save**: write the z range, default-fill missing layers. Makes the height change
   save-compatible (old saves load).
3. **Sparse levels in the sim** (PZ's trick): keep a per-layer "any non-uniform submap in the bubble"
   bit; skip empty layers in the z loops (`build_map_cache`, lightmap, vision, vehicle caches, monster
   z-visibility) and allocate `level_cache` lazily. This should bring the +35-50 % turn cost back to
   near zero for empty sky.
4. **Active z window**: full light/vision only for `player.z ± N` (e.g. 3) plus layers with content in
   line of sight; higher floors dormant until entered (like CDDA's submaps outside the bubble).
5. Then raise `OVERMAP_HEIGHT` (20-30) and add tall mapgen.
6. **Client cutaways + skyline**: hide floors above the player when indoors (we already have
   `view_z_max`); draw far or above-range buildings as static impostor meshes from overmap ids.
Order matters: 1-3 before 5, otherwise every turn pays for the empty sky.
