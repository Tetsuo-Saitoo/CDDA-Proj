# TASKS

## State
Wave 1 done; wave 2 started with B2. Client: C1 + C2 done against the mock (Godot 4.7.2 at `D:\Tools\Godot\`). M0 bridge done: the client can run a live CDDA game in-process (`--live`). Plan, blocks and agent waves: [PLAN.md](PLAN.md). Build steps: [docs/BUILD.md](docs/BUILD.md).
Engine decided: **Godot 4**. CDDA source **0.I-1** in `cdda/` (own git repo: `upstream` = pristine, `fp3d` = ours).
Project root is a git repo (`main`); cdda/ is a separate repo on branch `fp3d`. Both committed locally, no GitHub remote yet. vcpkg lives at `D:\vcpkg`.

## Open tasks
- [x] A1 MSVC build works (game, cata_test-tiles, fp3d-headless). Test baseline (seed 1): 1144/1155 pass, see Key facts
- [x] B1 `fp3d-headless` boots CDDA windowless (~25 s), finds a town, writes a snapshot JSON (`contracts/mock/snapshot_town.json`)
- [x] B2 slice 1: game loop on a worker thread behind `fp3d::bridge`; `fp3d-sim-test` passes open door / pick up / eat
- [x] B2 slice 2: `direction`/`target` requests (look_around, target_ui), activities, save/quit/reload, D3 clock in the bridge (real time, timescale, pause, auto-pause, interrupt); `fp3d-sim-test` 8/8
- [ ] B2 leftovers: peeking's blind throw/fire (`peek_action`); `fp3d::interrupt()` and auto-travel (`has_destination`) untested; game-over/death path to the client
- [ ] B2 tech debt: CDDA's SDL window is created hidden because game code calls `tilecontext` directly (~70 sites). Replace with a headless tile context later
- [x] B3 Snapshot API (`fp3d/snapshot.*`, `contracts/snapshot.md`); `fp3d-snapshot-test` passes
- [x] B4 Event bus (`fp3d/events.*`, `contracts/events.md`): sound, message, attack, damage, projectile, explosion, death, anim, turn_end; `fp3d-events-test` passes
- [ ] B4 leftovers: `ui_sound` and `sfx::` sound ids (stubs while SOUND is off), melee technique, bullet ammo itype, spell area effects
- [x] B5 Threading: action queue in the bridge (`queue_action`, 32 max, taken at timed requests, held while paused, cleared by auto-pause); snapshot/event/request handoffs are mutex-guarded; checked by `fp3d-sim-test`
- [ ] B5 leftover: ThreadSanitizer run on Linux CI (needs A3; MSVC has no TSan)
- [x] B6 Id tables (`fp3d/id_tables.*`, `contracts/id_tables.md`): ter/furn/trap/field/itype/mtype/vpart definitions, session tables pre-filled sorted, `ids_generation` in snapshots, `contracts/mock/id_tables.json`; `fp3d-ids-test` passes
- [ ] B6 follow-ups: client reads `id_tables.json` (C2 leftover below); `tools/coverage` could read it instead of parsing CDDA's JSON
- [x] C1 Coordinates (`client/scripts/world/coords.gd`) and C2 terrain mesher (`terrain_mesher.gd`, `world_view.gd`), fly camera, hostile-input loader (`snapshot.gd`); headless tests pass
- [x] M0 bridge: GDExtension `bridge/` (godot-cpp in `bridge/godot-cpp`, not in git) → `client/bin/fp3d_cdda.windows.x86_64.dll`, class `CddaSim` (`contracts/bridge_api.md`); client `LiveSession` + `main.gd --live` (debug UI: camera-relative walking, numbered menu answers); `client/tests/live_test.gd` passes
- [ ] Bridge leftovers: snapshot JSON is built and parsed on Godot's main thread (move to a worker or a binary format); one game per process (no restart after stop, no loading saves yet); the live HUD and walking are a debug stand-in (prompts use E3 now)
- [ ] C2 leftovers: use ter flags / `connect_groups` from `contracts/mock/id_tables.json` (B6 done) instead of name rules (`terrain_catalog.gd`); stairs/ramp direction is a guess; darken by `vis`/`light` (C6); real ramp wedges
- [ ] C3 props (furniture, items); C7 z-level view beyond the PgUp/PgDn cutaway
- [x] E3 generic UI-request renderer: `client/scripts/ui/` (`RequestUI` + one widget per kind: list for menu/key/item_select/item_multi, popup, string, direction, target; CDDA colour tags -> BBCode in `cdda_text.gd`); main.gd uses it; `tests/ui_tests.gd` (in run_tests) feeds fake requests
- [ ] E3 leftovers: not yet tried in a live game; target cursor isn't drawn in the 3D view and can't be picked with the mouse there (`RequestUI.set_target_cursor` is ready for E2); creature names for target candidates (client doesn't parse snapshot creatures yet); the `number` kind isn't sent by the bridge (query_int goes through `string`); CDDA's own menu hotkeys aren't sent
- [ ] A3 CI (GitHub Actions) — needs a GitHub repo; ask the user before creating one
- [ ] A4 Upstream merge playbook (tarball has no git history: fetch tag 0.I-1 from GitHub as merge base)
- [ ] Contracts: review v0 drafts in `contracts/` with block C/E/G leads before wave 2
- [ ] H1 Write more registry entries (furniture, monsters) once models exist; H3 tileset placeholders
- [x] User: art direction decided 2026-11-02: low-poly-ish, but with enough environmental detail (clutter, trim, props) that places read well. H blocks and the registry follow this
- [ ] User: real-time vs turn-based default

Later waves: see PLAN.md "Agent waves".

## How-to
- Each agent takes one sub-block ID from PLAN.md, works on branch `blk/<ID>`, owns only that block's directory.
- Contract changes go through the B lead; update TASKS.md + WORKLOG.md when a sub-block is done.
- Edits inside `cdda/` go under `cdda/src/fp3d/` or carry a `// FP3D:` / `# FP3D:` marker.
- Art coverage: `python -I tools/coverage/coverage.py --data cdda/data/json` (3 s).

## Key facts
- Client: run `D:\Tools\Godot\Godot_v4.7.2-stable_win64.exe --path client` (keys in the HUD; `-- --snapshot=<path>` loads another file). Tests: `Godot_v4.7.2-stable_win64_console.exe --headless --path client --import` once, then `--headless --path client --script res://tests/run_tests.gd` (also runs the E3 UI tests). The 363-submap mock builds in ~0.45 s, 500 k vertices.
- Client axes: 1 tile = 1 m, 1 z = 3 m, east = +X, south = +Z; Godot origin = bubble corner, rebased on shift. Walls fill their tile. Godot's JSON gives every number as a float.
- CDDA's sun azimuth (`env.sun_az_deg`) is measured from the south, positive toward the west (calendar.cpp). `t_soil` is solid earth (a wall), not a floor.
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
- Bridge facts: the main loop polls on a 125 ms timer even with animations off (hooked in `get_player_input`). `choose_direction`, `look_around` and `target_ui::run` (EDGE_SCROLL timeout) are replaced by one request each. `init_interface()` itself does SDL init, then options init+load (boot mirrors main). `game::start_game` is private: use `fp3d_game_access` (one friend line in game.h).
- Never use CDDA's `init_crash_handlers()` in automated runs: it shows an SDL message box and hangs. On MSVC, signal handlers are per thread; fp3d-sim-test uses a vectored handler that prints the stack and exits 3.
- A CMake re-configure can fail on vcpkg's SDL2_ttf (`Freetype::Freetype` not found); `cmake --preset fp3d-msvc --fresh` fixes it.
- Agent tooling: in Bash heredocs, `\n` inside Python strings reached C++ files as real newlines. Use the Edit tool for C string escapes. Python's `read_text`/`write_text` default to cp1252 here and `write_text` empties the file before failing on non-cp1252 text: use `read_bytes().decode("utf-8")` / `write_bytes`. It also turns LF into CRLF (harmless: `core.autocrlf` is on).
- `input_context::get_registered_actions()` / `is_action_registered()` exist only in Android builds.
- Real-time clock lives in `fp3d/bridge.cpp` (`pace_turn` in `do_turn` before the turn advances; the main-loop request is `timed`). Auto-pause hooks safe mode's STOP in `game::mon_info_update` (reason "hostile spotted").
- Random starts can put an NPC next to you or start in an unlit room: `fp3d-sim-test` kills NPCs and gives the avatar `DEBUG_NIGHTVISION`.
- Snapshot facts: a capture takes ~110 ms (RelWithDebInfo, full bubble); unchanged submaps are shared pointers. CDDA's vehicle caches are lazy (insides/fake parts refresh on `actualize`, e.g. a map shift), so vehicle roof flags can change on a shift: a real revision bump, not a bug. Fresh loads need `rebuild_vehicle_level_caches` + `build_map_cache` (boot.cpp does it).
- CDDA's safe mode refuses `pause` and moves while a hostile is in view (only a message, no turn passes): scripted tests send `safemode` first.
- Id table facts: 1109 ter, 660 furn, 9913 items, 1155 monsters, 702 vehicle parts (0.I + dda). Wall symbols are CDDA line-drawing codes, exported as "". `trap::visibility` is private (not exported). Connect group names come from `fp3d_connect_group_names()` (FP3D addition in mapdata.cpp).
- Event facts: hooks cost one atomic load while events are disabled (CDDA's unit tests never enable them). Sounds are taken where CDDA works out what the player hears (`process_sound_markers`), not in `sounds::sound`. `fp3d-sim-test` sees ~350 turn_end events over its 8 goals: a client must drain often or lose them first.
- Agent tooling: `for( x : make_shared_thing()->member )` dangles (the temporary shared_ptr dies before the loop): keep the snapshot in a variable.
- Bridge facts: CDDA runs on its own 8 MB-stack thread in Godot's process; CDDA's hidden window uses SDL's software renderer whenever the bridge is active (no GPU device or driver threads for nothing). After a headless boot, call `fp3d::shutdown_world()` on the game thread before exit (the DLL and `fp3d-sim-test` do): CDDA's `atexit( SDL_Quit )` otherwise runs before its static tile caches free their textures (crash at exit), and in a DLL it runs inside DllMain and deadlocks on SDL's timer thread (Godot hung on exit). Stack dumps of a hung process (no debugger installed): `python -I tools/debug/stacks.py <pid>`. Boot ~30 s; `stop()` waits for boot to finish. Godot locks the DLL while running: close it before building. Snapshot JSON for 3 levels is ~0.9 MB.
- Id tables: 108 items have colour `c_unset`; `color_manager::get_name` raises a debug message for those (a popup outside test mode), so the tables use their own colour map.
- Request UI (E3): `RequestUI.show_request(req)` -> `answered(answer)` -> `LiveSession.answer()`. Keys reach it in `_input`, before main.gd's `_unhandled_input`; keys a widget doesn't use fall through (WASD flies). Directions and the target cursor are camera-relative through `direction_mapper`. RAW_KEY reads and timed (main-loop) requests never show: main.gd answers / skips them. Godot 4.7's Range doesn't emit `value_changed` when a script sets `value`: tests emit the signal themselves.
- Planned scale: 1 tile = 1 m, 1 z-level = 3 m, 4×4 sub-tiles per tile.
