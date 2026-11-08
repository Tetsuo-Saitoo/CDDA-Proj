# CDDA-3D

Cataclysm: Dark Days Ahead (0.I-1) as a 3D first-person game in Godot 4. CDDA's own C++ simulation runs inside
the game and still decides everything. This repo holds the Godot client, the bridge between the two (a
GDExtension) and the plan.

**Status: early.** You can start or load a CDDA game and play it turn by turn in 3D, in first person, with
placeholder art: walk, use CDDA's action keys (pick up, wield, eat, open, ...), strike with either hand and
click things to look at them; monsters are green capsules for now. Every key can be rebound (F1). VR has its
first step (block L1 in [PLAN.md](PLAN.md)): walk around the world in a PC VR headset, no interaction yet.
The mock town needs only Godot 4.7.2, on Windows or Linux (macOS has no PC VR): see
[docs/BUILD.md](docs/BUILD.md) step 6. Live CDDA games run on Windows and Linux.

## Get the code

```bash
git clone --recursive https://github.com/Tetsuo-Saitoo/CDDA-Proj cdda-3d
```

`--recursive` also fetches `cdda/`: [CDDA-3D-code](https://github.com/Tetsuo-Saitoo/CDDA-3D-code), CDDA 0.I-1
with this project's changes and the game data, as a git submodule. Cloned without it: run
`git submodule update --init` in `cdda-3d/`. If you cloned CDDA-3D-code into `cdda/` by hand before, the same
command after `git pull` takes that folder over. After later pulls, `git submodule update` brings `cdda/` along.
On Windows, CDDA has file paths near Windows' 260-character limit: clone into a short folder path, or run
`git config --global core.longpaths true` first.

Building needs Windows (Visual Studio 2022 Build Tools, vcpkg) or Linux (GCC, CMake, SDL2), and Godot 4.7.2: see
[docs/BUILD.md](docs/BUILD.md). To skip building, take the bridge (Windows DLL or Linux `.so`) from the newest
[release](https://github.com/Tetsuo-Saitoo/CDDA-Proj/releases)
(only Godot 4.7.2 needed then).

## Where things are

- [PLAN.md](PLAN.md): architecture, blocks, milestones. [TASKS.md](TASKS.md): current state and open tasks.
- `client/`: Godot project. `bridge/`: GDExtension. `contracts/`: data formats between the two.
- `cdda/` (repo CDDA-3D-code, branch `fp3d`): the CDDA fork; our changes are in `src/fp3d/` or marked `FP3D:`.

## Licence

CC BY-SA 3.0, like CDDA: see [LICENSE.md](LICENSE.md).
