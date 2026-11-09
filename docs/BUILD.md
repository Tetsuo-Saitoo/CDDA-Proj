# Building (Windows, MSVC)

Needs: Visual Studio 2022 Build Tools (C++ workload, CMake, Windows SDK), Git, Python 3.

1. **vcpkg** (once). It must sit on a path without spaces:
   ```bash
   git clone https://github.com/microsoft/vcpkg.git D:/vcpkg
   D:/vcpkg/bootstrap-vcpkg.bat -disableMetrics
   ```
2. **Source.** `cdda/` holds CDDA **0.I-1** (from the release tarball). It is its own git repo,
   CDDA-3D-code, and a submodule of this one (`git submodule update --init` fills an empty `cdda/`): branch
   `upstream` is pristine, branch `fp3d` carries our changes. The project pins one `fp3d` commit; to work on
   it, `git -C cdda switch fp3d`, and after committing there, `git add cdda` and commit in the project root. Copy `tools/build/CMakeUserPresets.json` into `cdda/` (upstream
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
   - `src/fp3d/RelWithDebInfo/fp3d-chargen-test.exe`: character creation: catalog, valid choices applied, bad ones refused; run from `cdda/`, ~40 s, prints `all checks passed`. Client side live: `godot --headless --path client --script res://tests/chargen_live_test.gd` (~1 min)
   - `src/fp3d/RelWithDebInfo/fp3d-events-test.exe`: B4 test, makes each kind of event happen next to the player and checks what the bus queues (and leaves out); run from `cdda/`, ~40 s, prints `all checks passed`
5. **Godot bridge** (GDExtension, API in `contracts/bridge_api.md`). No compiler? Take
   `fp3d_cdda.windows.x86_64.dll` (Windows) or `fp3d_cdda.linux.x86_64.so` (Linux, needs the system's SDL2,
   SDL2_image, SDL2_ttf and glibc 2.38+) from the newest GitHub release of CDDA-Proj, put it in `client/bin/`,
   check its SHA256 (`Get-FileHash` / `sha256sum`) against the release notes, and skip to the tests and play below; `cdda/`
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
     prints `live tests: all passed`. It plays a new game, saves it while paused (`save_game`), plays a turn
     more and stops, then starts a second Godot run (`-- --load`, output prefixed `|`) that loads the save and
     checks turn and position. It plays in
     `%APPDATA%\Godot\app_userdata\CDDA-3D\cdda-test\` (listing checks in `...\cdda-list-test\`).
   - Play: `Godot_v4.7.2-stable_win64.exe --path client -- --live`: continues your game in world `fp3d-live`
     (under `...\CDDA-3D\cdda\`), or starts one there when it has no save; `--live --new` starts over and
     **replaces** `fp3d-live` with its saves. **F5** saves and plays on (also while paused; in a prompt or a long
     activity it waits for the game to get back to its main loop), closing the window saves first (gives up after
     20 s, e.g. asleep), and it autosaves every 5 minutes of play when something changed. A death removes the
     character's save (CDDA), so the next `--live` starts a new game. Another world: `--live --world=<world>
     [--save=<character>]` (first save of the world if no `--save`; `--save` alone looks in `fp3d-live`); this
     never deletes anything.
     Vanilla CDDA 0.I worlds work when copied into `...\CDDA-3D\cdda\save\`.
   - Views (with or without `--live`): first person by default, eyes 1.6 m up; **V** switches to the outside
     (fly) camera and back; `--view=outside` starts outside (so does `--camera=`, unless `--view=first`). First
     person: hold RMB and move the mouse to look (or the right stick); live, WASD / left stick, arrows and
     numpad step where you look (held keys keep stepping, one step queued at a time), `[ ]` stairs; on the
     mock town WASD walks (walls stop you, doors don't), Shift faster, `[ ]` level down / up, Home back to the
     player. Bindings are Godot actions (`client/scripts/input/input_actions.gd`, defaults until E1).
   - Live game actions: **E** uses what your hands hold on the square you face, or examines it (a rubber
     hose in one hand and a container in the other siphon a vehicle's tank into the container; a held jerrycan
     refuels a vehicle; a held container fills from water, a keg or a puddle; no menus; the hands panel bottom
     right, and the controllers in VR, show it filling); **H** holds a carried item in the left (off) hand, **Shift+H**
     puts it away; X examines with a direction prompt. CDDA's keys where WASD/V/R left them free (g pick up, i inventory, o/c open/close, q wield, u apply, z smash, t throw, f fire; Shift + E/W/T/R/D/U/B/G eat, wear, take off, read, drop, unload, butcher, grab; ! safe mode; 1 / 2 strike the square you face with the left (off: what it holds, else unarmed) / right (main, weapon) hand); CDDA then asks through the usual prompts. Left click: look at what's under the mouse (line, distance, what's there); Esc clears it. Compass at the top.
   - Every game key can be rebound: F1 opens the key menu (click a slot, press a key or mouse button; Esc cancels, Backspace clears; `-- --keys` starts with it open). Changes are saved at once to `keys.json` in Godot's user folder (Windows `%APPDATA%\Godot\app_userdata\CDDA-3D\`, Linux `~/.local/share/godot/app_userdata/CDDA-3D/`); delete it or press Reset all for the defaults. Prompt keys (Enter, Esc, arrows in lists) and F1 stay fixed.
   - Creatures are placeholder figures by body type; `-- --demo-creatures` shows one of each near the player in the mock town (they walk and attack every few seconds), `-- --creatures=snap` makes them jump from square to square instead of walking.
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
   installed and `XR_RUNTIME_JSON` isn't set, start SteamVR and wait for it when it isn't running yet (the game
   can't open a VR session before SteamVR's compositor is up), and pass options on (`play_vr.cmd --live`). By hand:
   ```powershell
   Godot_v4.7.2-stable_win64.exe --xr-mode on --path client -- --vr          # mock town
   Godot_v4.7.2-stable_win64.exe --xr-mode on --path client -- --live --vr   # a live game (Windows)
   ```
   On Linux: `./Godot_v4.7.2-stable_linux.x86_64 --xr-mode on --path client -- --vr` (add `--live` with the
   `.so` built). Without the bridge, Godot prints once that `fp3d_cdda.gdextension` has no library for this
   platform; the mock town still runs.
   Windows Mixed Reality headsets only run DirectX: add `--rendering-driver d3d12` before `--path`.
   Controls (Quest / Index / Pico / WMR, "quest" layout): left stick walks where you look (walls stop you, doors
   don't); right stick left/right turns 45°; right stick forward aims a teleport (green = OK) and jumps on
   release; right B / A: level up / down; left Y: back to the player (WMR / Index: trackpad click, right up /
   down half = level up / down, left = back to the player). Vive wands ("vive" layout): left pad touched walks;
   right pad click left/right turns, held up aims the teleport, down = level down; right menu = level up; left
   pad click = back to the player. **Left menu button** (Index: left stick click) opens the settings in the
   headset: stick up/down picks, left/right or trigger changes, menu closes and saves them to `vr.json` in
   Godot's user folder. Settings: move smooth/teleport, move toward head/hand, speed, turn snap/smooth/off, snap
   angle, smooth turn speed, vignette (off or strength), blink on jumps, move with the right stick, controller
   layout (auto from the runtime / quest / vive), hands (finger tracking when the runtime gives it, else fingers
   from trigger/grip/thumb; or simple boxes). Command-line options win over the file: `--vr-move= --vr-move-dir=
   --vr-speed= --vr-turn= --vr-snap= --vr-turn-speed= --vr-vignette= --vr-blink=on|off --vr-swap-sticks=on|off
   --vr-layout=auto|quest|vive --vr-hands=auto|buttons|boxes`. Every 10 s frame times go to the
   console and to `vr_perf.log` in Godot's user folder (Windows `%APPDATA%\Godot\app_userdata\CDDA-3D\`,
   Linux `~/.local/share/godot/app_userdata/CDDA-3D/`; numbers and the GPU name only; testers can send it). Controller bindings: `client/openxr_action_map.tres` (Godot's defaults plus Vive, Index and WMR profiles from `tools/vr/add_controller_profiles.gd`).
   The console also logs the live game's state, its prompts and the VR session's states.
   Without a headset or runtime the normal view starts and the HUD says why. A live game's prompts still show
   only on the desktop window (L4 brings them into VR).
7. **Art coverage** (no build needed):
   `python -I tools/coverage/coverage.py --data cdda/data/json` → `tools/out/coverage_*.csv`
8. **Linux AppImage** (one file with everything: the exported client, the bridge, CDDA's data and tilesets, SDL2).
   Built in WSL Ubuntu 24.04 (or such a Linux) with the step 5 Linux packages plus `squashfs-tools`; runs on
   x86_64 Linux with glibc 2.38 or newer (Arch, Fedora 39+, Ubuntu 24.04+). One command from Windows:
   `wsl.exe -d Ubuntu-24.04 --cd "<repo>" -- bash tools/build/appimage.sh` → `tools/out/appimage/`
   (`CDDA-3D-x86_64.AppImage`, its `.sha256`, `THIRD_PARTY_LICENSES.txt`). The first run downloads Godot's
   export templates (1.3 GB, only the Linux release template is kept) and the AppImage runtime into `~/tools`,
   both checked against pinned SHA-256; it needs Godot 4.7.2's Linux editor (`$GODOT`, else
   `~/tools/godot-4.7.2/`). Playing: `chmod +x CDDA-3D-x86_64.AppImage`, then `./CDDA-3D-x86_64.AppImage`
   continues the live game (`--new` starts over; F5 saves, closing saves) on the desktop, `--vr` in VR (the system's OpenXR runtime; SteamVR is preferred and
   started when installed, like `tools/vr/play_vr.sh`), `--town` the mock town; other step 5/6 options pass
   through. Saves, keys and logs stay in `~/.local/share/godot/app_userdata/CDDA-3D/`; no VR runtime is inside.
   Needs FUSE 3 (`fusermount3`; Arch: `fuse3`), else run it with `--appimage-extract-and-run`.
