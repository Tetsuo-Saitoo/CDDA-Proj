# CDDA-3D

Cataclysm: Dark Days Ahead (0.I-1) as a 3D first-person game in Godot 4. CDDA's own C++ simulation runs inside
the game and still decides everything. This repo holds the Godot client, the bridge between the two (a
GDExtension) and the plan.

**Status: early.** You can start or load a CDDA game and walk it turn by turn in 3D with placeholder art. VR
has its first step (block L1 in [PLAN.md](PLAN.md)): walk around the world in a PC VR headset, no interaction
yet. The mock town needs only Godot 4.7.2, on Windows or Linux (macOS has no PC VR): see
[docs/BUILD.md](docs/BUILD.md) step 6. Live CDDA games run on Windows only for now.

## Get the code

```bash
git clone https://github.com/Tetsuo-Saitoo/CDDA-Proj cdda-3d
cd cdda-3d
git clone -b fp3d https://github.com/Tetsuo-Saitoo/CDDA-3D-code cdda
```

Building needs Windows, Visual Studio 2022 Build Tools, vcpkg and Godot 4.7.2: see [docs/BUILD.md](docs/BUILD.md).
To skip building, take the bridge DLL from the newest [release](https://github.com/Tetsuo-Saitoo/CDDA-Proj/releases)
(only Godot 4.7.2 needed then).

## Where things are

- [PLAN.md](PLAN.md): architecture, blocks, milestones. [TASKS.md](TASKS.md): current state and open tasks.
- `client/`: Godot project. `bridge/`: GDExtension. `contracts/`: data formats between the two.
- `cdda/` (repo CDDA-3D-code, branch `fp3d`): the CDDA fork; our changes are in `src/fp3d/` or marked `FP3D:`.

## Licence

CC BY-SA 3.0, like CDDA: see [LICENSE.md](LICENSE.md).
