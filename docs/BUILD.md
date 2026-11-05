# Building (Windows, MSVC)

Needs: Visual Studio 2022 Build Tools (C++ workload, CMake, Windows SDK), Git, Python 3.

1. **vcpkg** (once). It must sit on a path without spaces:
   ```bash
   git clone https://github.com/microsoft/vcpkg.git D:/vcpkg
   D:/vcpkg/bootstrap-vcpkg.bat -disableMetrics
   ```
2. **Source.** `cdda/` holds CDDA **0.I-1** (from the release tarball). It is its own git repo
   (`git clone -b fp3d https://github.com/Tetsuo-Saitoo/CDDA-3D-code cdda` from the project root): branch
   `upstream` is pristine, branch `fp3d` carries our changes. Copy `tools/build/CMakeUserPresets.json` into `cdda/` (upstream
   gitignores that file). It inherits CDDA's `windows-tiles-sounds-x64-msvc` preset, points `VCPKG_ROOT` at
   `D:/vcpkg`, and turns off translations and CDDA's own sound (vcpkg's SDL2_mixer needs libxmp).
3. **Configure + build** (first run also builds SDL2 etc. through vcpkg, ~20 min):
   ```powershell
   $cm = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
   cd cdda
   & $cm --preset fp3d-msvc
   & $cm --build out/build/fp3d-msvc --config RelWithDebInfo --parallel 16
   ```
   The log goes to `cdda/out/build-log.txt` when you use the command from WORKLOG.
4. **Outputs** (in `cdda/out/build/fp3d-msvc/`):
   - `src/RelWithDebInfo/cataclysm-tiles.exe`: the normal game
   - `tests/RelWithDebInfo/cata_test-tiles.exe`: CDDA's unit tests (run from `cdda/`)
   - `src/fp3d/RelWithDebInfo/fp3d-headless.exe <out.json> [z_below] [z_above] [ids.json]`: B1 smoke test (run from `cdda/`), writes a snapshot of a town at noon as JSON (format in `contracts/snapshot.md`) and, with a 4th argument, the id tables (`contracts/id_tables.md`). The mocks: `fp3d-headless ..\contracts\mock\snapshot_town.json 1 1 ..\contracts\mock\id_tables.json`
   - `src/fp3d/RelWithDebInfo/fp3d-sim-test.exe`: B2 test, plays 8 goals through the bridge (door, pickup, eat, look, throw, wait, real time + auto-pause, save/reload) and publishes a snapshot before each request and drains events; run from `cdda/`, ~1.5 min, prints `8/8 goals passed`, `snapshots: ok`, `events: ok` and `queue: ok`
   - `src/fp3d/RelWithDebInfo/fp3d-snapshot-test.exe`: B3 test, checks snapshots against CDDA's submap buffer, sharing, revisions, uids and a map shift; run from `cdda/`, ~40 s, prints `all checks passed`
   - `src/fp3d/RelWithDebInfo/fp3d-ids-test.exe`: B6 test, checks the id tables against CDDA's data, stable indices, snapshot ids resolving, the JSON; run from `cdda/`, ~40 s, prints `all checks passed`
   - `src/fp3d/RelWithDebInfo/fp3d-events-test.exe`: B4 test, makes each kind of event happen next to the player and checks what the bus queues (and leaves out); run from `cdda/`, ~40 s, prints `all checks passed`
5. **Godot bridge** (GDExtension, API in `contracts/bridge_api.md`). No compiler? Take
   `fp3d_cdda.windows.x86_64.dll` from the newest GitHub release of CDDA-Proj, put it in `client/bin/`, check
   its SHA256 (`Get-FileHash`) against the release notes, and skip to the tests and play below; `cdda/`
   (CDDA-3D-code) is still needed for the game data. To build it instead: get godot-cpp once (MIT; it ships Godot 4.7's
   API, so nothing else is needed). We use commit `e103d348` (2026-10-30):
   ```bash
   git clone --depth 1 https://github.com/godotengine/godot-cpp bridge/godot-cpp
   ```
   Re-configure (`& $cm --preset fp3d-msvc --fresh`): `cdda/src/fp3d/CMakeLists.txt` adds `bridge/` when
   godot-cpp is there. Build target `fp3d-cdda` (first time ~10 min for godot-cpp); it copies
   `fp3d_cdda.windows.x86_64.dll` (~40 MB, imports only Windows DLLs) to `client/bin/`. Close Godot first: it
   locks the DLL.
   - Live test, ~2 min: `Godot_v4.7.2-stable_win64_console.exe --headless --path client --script res://tests/live_test.gd`
     prints `live tests: all passed`. It plays a new game, saves it, then starts a second Godot run
     (`-- --load`, output prefixed `|`) that loads the save and checks turn and position. It plays in
     `%APPDATA%\Godot\app_userdata\CDDA-3D\cdda-test\` (listing checks in `...\cdda-list-test\`).
   - Play: `Godot_v4.7.2-stable_win64.exe --path client -- --live` (new game each start, world `fp3d-live` under
     `...\CDDA-3D\cdda\`; keys in the HUD). Load a save instead with `--live --world=<world> [--save=<character>]`
     (first save of the world if no `--save`; `--save` alone looks in `fp3d-live`); this never deletes anything,
     but plain `--live` replaces `fp3d-live` with its saves, so resume those with `--live --world=fp3d-live`.
     Vanilla CDDA 0.I worlds work when copied into `...\CDDA-3D\cdda\save\`.
   - **Linux** (a Linux PC or WSL; Ubuntu 24.04 / Arch). Packages: Ubuntu `sudo apt install build-essential cmake
     ninja-build git pkg-config libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev libfreetype-dev zlib1g-dev
     libbz2-dev`; Arch `sudo pacman -S --needed base-devel cmake ninja git sdl2 sdl2_image sdl2_ttf freetype2`.
     Then, with godot-cpp cloned as above:
     ```bash
     cp tools/build/CMakeUserPresets.json cdda/ && cd cdda
     cmake --preset fp3d-linux
     cmake --build out/build/fp3d-linux --target fp3d-cdda   # -> client/bin/fp3d_cdda.linux.x86_64.so
     ```
     The `.so` links SDL2 from the system and exports only `fp3d_cdda_init`. Under the bridge, CDDA's hidden
     window uses SDL's `offscreen` driver, so the game thread needs no display.
     From Windows through WSL (Ubuntu 24.04, packages as above): `bash tools/build/wsl_build.sh [targets]` from
     the checkout under `/mnt/...`. It copies the tree (no `.git`, no build output) to `~/cdda3d` (Linux disk
     is much faster), builds there with one job per 2 GB of RAM (more get killed by the OOM killer), and
     copies the `.so` back to `client/bin/`. `KEEP_GOING=1` lists every compile error in one run. Tests on
     Linux run from `~/cdda3d/cdda` (`out/build/fp3d-linux/src/fp3d/fp3d-*-test`) and with the Linux Godot
     (`--headless --path ~/cdda3d/client --script res://tests/live_test.gd`).
6. **VR** (block L1: PC VR through OpenXR, scripts in `client/scripts/vr/`). The mock town needs only Godot
   4.7.2 (the official build from godotengine.org; distro packages may be older) and works on **Windows and
   Linux**; a live game needs the bridge (step 5): Windows and Linux. macOS has no PC VR
   runtime, so no VR there (the flat mock town runs). Start the headset's OpenXR runtime first: Windows:
   SteamVR or the Meta Quest app (Link / Air Link); Linux: SteamVR, or Monado / WiVRn / ALVR (Quest over
   Wi-Fi), set as the active OpenXR runtime. The launchers `tools\vr\play_vr.cmd` (Windows) and
   `tools/vr/play_vr.sh` (Linux; Godot from `$GODOT` or the PATH) prefer SteamVR's runtime when SteamVR is
   installed and `XR_RUNTIME_JSON` isn't set, and pass options on (`play_vr.cmd --live`). By hand:
   ```powershell
   Godot_v4.7.2-stable_win64.exe --xr-mode on --path client -- --vr          # mock town
   Godot_v4.7.2-stable_win64.exe --xr-mode on --path client -- --live --vr   # a live game (Windows)
   ```
   On Linux: `./Godot_v4.7.2-stable_linux.x86_64 --xr-mode on --path client -- --vr` (add `--live` with the
   `.so` built). Without the bridge, Godot prints once that `fp3d_cdda.gdextension` has no library for this
   platform; the mock town still runs.
   Windows Mixed Reality headsets only run DirectX: add `--rendering-driver d3d12` before `--path`.
   Controls: left stick walks where you look (walls stop you, doors don't); right stick left/right turns 45°;
   right stick forward aims a teleport (green = OK) and jumps on release; right B / A: level up / down; left
   Y: back to the player. Options after `--`: `--vr-move=teleport` (no stick walking), `--vr-turn=smooth`,
   `--vr-snap=<deg>`, `--vr-speed=<m/s>`, `--vr-vignette=<0-1>` (0 = off). Every 10 s frame times go to the
   console and to `vr_perf.log` in Godot's user folder (Windows `%APPDATA%\Godot\app_userdata\CDDA-3D\`,
   Linux `~/.local/share/godot/app_userdata/CDDA-3D/`; numbers and the GPU name only; testers can send it). The first run writes Godot's default controller bindings to `client/openxr_action_map.tres`.
   Without a headset or runtime the normal view starts and the HUD says why. A live game's prompts still show
   only on the desktop window (L4 brings them into VR).
7. **Art coverage** (no build needed):
   `python -I tools/coverage/coverage.py --data cdda/data/json` → `tools/out/coverage_*.csv`
