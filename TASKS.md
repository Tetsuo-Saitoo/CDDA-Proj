# TASKS

## State
Wave 1 done; wave 2 started with B2. Plan, blocks and agent waves: [PLAN.md](PLAN.md). Build steps: [docs/BUILD.md](docs/BUILD.md).
Engine decided: **Godot 4**. CDDA source **0.I-1** in `cdda/` (own git repo: `upstream` = pristine, `fp3d` = ours).
Project root is a git repo (`main`); cdda/ is a separate repo on branch `fp3d`. Both committed locally, no GitHub remote yet. vcpkg lives at `D:\vcpkg`.

## Open tasks
- [x] A1 MSVC build works (game, cata_test-tiles, fp3d-headless). Test baseline (seed 1): 1144/1155 pass, see Key facts
- [x] B1 `fp3d-headless` boots CDDA windowless (~25 s), finds a town, writes `contracts/mock/town_bubble.json`
- [x] B2 slice 1: game loop on a worker thread behind `fp3d::bridge`; `fp3d-sim-test` passes open door / pick up / eat
- [ ] B2 slice 2: dedicated `direction`/`target` request kinds; hook `look_around`/aiming; multi-step activities; save/quit path; real-time clock hooks (D3)
- [ ] B2 tech debt: CDDA's SDL window is created hidden because game code calls `tilecontext` directly (~70 sites). Replace with a headless tile context later
- [ ] B3 Snapshot API (mock format in town_bubble.json is a first cut: ter/furn index grids per z)
- [ ] B6 Id tables from C++ (until then tools/coverage reads JSON directly)
- [ ] A3 CI (GitHub Actions) — needs a GitHub repo; ask the user before creating one
- [ ] A4 Upstream merge playbook (tarball has no git history: fetch tag 0.I-1 from GitHub as merge base)
- [ ] Contracts: review v0 drafts in `contracts/` with block C/E/G leads before wave 2
- [ ] H1 Write more registry entries (furniture, monsters) once models exist; H3 tileset placeholders
- [ ] User: art direction (stylised low-poly vs realistic), real-time vs turn-based default

Later waves: see PLAN.md "Agent waves".

## How-to
- Each agent takes one sub-block ID from PLAN.md, works on branch `blk/<ID>`, owns only that block's directory.
- Contract changes go through the B lead; update TASKS.md + WORKLOG.md when a sub-block is done.
- Edits inside `cdda/` go under `cdda/src/fp3d/` or carry a `// FP3D:` / `# FP3D:` marker.
- Art coverage: `python -I tools/coverage/coverage.py --data cdda/data/json` (3 s).

## Key facts
- CDDA: C++, JSON data (0.I: all items are type `ITEM`), licence CC-BY-SA 3.0, so this project must be too.
- Reality bubble 11×11 submaps of 12×12 tiles (132×132), z -10..+10 (`map_scale_constants.h`); 100 moves = 1 turn = 1 s.
- Game code is the OBJECT library `cataclysm-tiles-common`; tests link it with `SDL_MAIN_HANDLED` — so does fp3d-headless.
- `tests/test_main.cpp` `init_global_game_state()` is the reference for booting CDDA without a window.
- Built with SOUND and LOCALIZE off: vcpkg's SDL2_mixer config wants libxmp, which isn't installed. Game audio will come from Godot.
- `overmap_buffer.closest_city()` only searches generated overmaps: call `overmap_buffer.get()` first.
- CDDA's preset hard-codes `VCPKG_ROOT=C:/vcpkg`; our `CMakeUserPresets.json` (copy in tools/build/) overrides it.
- Data size: ~10.1k items, 1.1k monsters, 1.1k terrain, 659 furniture, 486 vehicle parts.
- 16 terrain registry entries already cover ~62 % of spawn-weighted terrain (73 % with looks_like).
- Test baseline, unmodified game code, seed 1: 11 failures. 5 are translation tests (LOCALIZE off). `limit_mod_size_bonus` fails even alone (a creature already stands on the spawn tile). It leaves a creature behind, which makes 4 `monsters_spawn_*` tests and `mission_goal_condition_test` fail in the full run; they pass alone.
- Delete `cdda/test_user_dir/` before each test run: tests write past games there, and a second run then fails `achievements_tracker` and `default_overmap_generation_has_non_mandatory_specials_at_origin`. After B2 with a clean dir: same 11 failures as baseline.
- Bridge facts: the main loop polls on a 125 ms timer even with animations off (hooked in `get_player_input`). `choose_direction` blinks on a timer (hooked). `init_interface()` itself does SDL init, then options init+load (boot mirrors main). `game::start_game` is private: use `fp3d_game_access` (one friend line in game.h).
- Never use CDDA's `init_crash_handlers()` in automated runs: it shows an SDL message box and hangs. On MSVC, signal handlers are per thread; fp3d-sim-test uses a vectored handler that prints the stack and exits 3.
- A CMake re-configure can fail on vcpkg's SDL2_ttf (`Freetype::Freetype` not found); `cmake --preset fp3d-msvc --fresh` fixes it.
- Agent tooling: in Bash heredocs, `\n` inside Python strings reached C++ files as real newlines. Use the Edit tool for C string escapes.
- Planned scale: 1 tile = 1 m, 1 z-level = 3 m, 4×4 sub-tiles per tile.
