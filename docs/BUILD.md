# Building (Windows, MSVC)

Needs: Visual Studio 2022 Build Tools (C++ workload, CMake, Windows SDK), Git, Python 3.

1. **vcpkg** (once). It must sit on a path without spaces:
   ```bash
   git clone https://github.com/microsoft/vcpkg.git D:/vcpkg
   D:/vcpkg/bootstrap-vcpkg.bat -disableMetrics
   ```
2. **Source.** `cdda/` holds CDDA **0.I-1** (from the release tarball). It is its own git repo: branch `upstream`
   is pristine, branch `fp3d` carries our changes. Copy `tools/build/CMakeUserPresets.json` into `cdda/` (upstream
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
5. **Art coverage** (no build needed):
   `python -I tools/coverage/coverage.py --data cdda/data/json` → `tools/out/coverage_*.csv`
