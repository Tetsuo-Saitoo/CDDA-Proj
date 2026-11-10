# The team

How the Claude sessions working on CDDA-3D are organised (user, 2026-11-09). One coordinator, six leads. Each
lead is a long-lived session in its own worktree, and splits its work into chunks for subagents
(`.claude/agents/`). PLAN.md says what to build, TASKS.md what's open, and this file who does it and how.

## Coordinator

The session "Cataclysm Dark Days Ahead 3D conversion" (`local_124c6391-cf51-4f7f-b449-8d3cec1b6ba4`), the one
the user talks to.
- Keeps TASKS.md priorities and hands tasks to leads. Answers questions that cross roles. Reports to the user.
- Merges finished lead branches and pushes them: the fork's `fp3d` first, then root `main` with the `cdda`
  pointer. It runs the tests on the merged result before pushing and tells the user afterwards (the user
  allowed merging and pushing freely, 2026-11-09).
- After every `fp3d` merge, rebuilds `fp3d-cdda` in the main checkout. The user's desktop shortcuts ("CDDA 3D"
  and "CDDA 3D (VR)") run that checkout's client with `--live`, so its `client/bin` DLL must be current.
- Fixes merge conflicts in shared files and archives sessions that are done.

## Leads

| Lead | Blocks (PLAN.md) | Owns | Starts with |
|---|---|---|---|
| Bridge and fork | B, D (sim side), J | `cdda/src/fp3d/**`, FP3D hooks in `cdda/src/*`, `bridge/**`, `contracts/bridge_api.md`, `contracts/ui_requests.md`, snapshot format | recipe matching and heat sources for L9, gun dirt for fouling, weak point ids for combat, vehicle cargo items |
| World and models | C, H, I | `client/scripts/world/**`, `client/scripts/camera/**`, `assets/**`, `contracts/assets.md`, `docs/MODELS.md`, `tools/coverage/` | model loading follow-ups, Seglectic's models, creatures and bodies, z-levels |
| Interaction and UI | E, G | `client/scripts/ui/**` (except combat files), `client/scripts/input/**`, `client/scripts/live/**` | E6 hands for mouse and keyboard, prompts, menus, HUD |
| VR | L | `client/scripts/vr/**` | L2 hands, L8 containers and L9 cooking in VR, headset fixes from the VR tester |
| Combat and weapons | F | `client/scripts/ui/aim_controller.gd`, `client/scripts/ui/weapon_viewmodel.gd`, future `client/scripts/combat/**`, fork `ranged.cpp`/`melee.cpp` hooks (with the bridge lead's review) | weak points, fouling, reload by hand, hit feedback |
| QA and release | A, K | `tools/build/`, `tools/release/`, `tools/debug/`, `docs/BUILD.md`, `.github/**`, `client/tests/run_tests.gd` and the live test scripts | CI, perf budgets, security review of merges, Linux build |

Shared files: `client/scripts/main.gd`, `TASKS.md`, `WORKLOG.md`, the fork's `src/fp3d/sim_test.cpp`.
- Keep edits to them small.
- In TASKS.md, change only your own task lines.
- Add one WORKLOG line per finished piece.
- In sim_test.cpp, add your checks in your own function. The bridge lead owns its structure.
- The coordinator sorts out conflicts in these files when merging.

Changing another lead's files: ask that lead (SendMessage) or the coordinator first. Contracts and the bridge
API change only with the bridge lead's OK.

## How a lead works

1. **Branches.** Work in your own worktree on your own branch: root `team/<role>`, and fork `fp3d-<role>`
   when the fork changes. Bring main and fp3d in before you report.
2. **Chunks.** Split each task into chunks. Give independent chunks to subagents in parallel:
   - `fork-dev`: C++ in the fork.
   - `client-dev`: GDScript in the client.
   - `test-runner`: builds and runs the suites.
   - `reviewer`: reads a diff for bugs and security.
   - the built-in `Explore`: searching the code.

   Brief each one fully, since it only knows what you tell it. Check what comes back (diff, tests) before you
   commit it.
3. **Done** means:
   - the tests pass: the sim test for fork changes, `run_tests.gd` for the client, and the live test when
     the bridge is involved;
   - TASKS.md and WORKLOG.md are updated;
   - it is committed on your branch;
   - you sent the coordinator a short report: branches, commits, tests, and what is not verified (for
     example not played by hand, not tried in a headset).
4. **Pushing and merging** into `main` or `fp3d` is the coordinator's job. Don't do either.
5. **Questions for the user** go through the coordinator, unless the user is talking to you directly.

## Rules for everyone

- **Client tests:** run only `res://tests/run_tests.gd` and the live scripts (`live_test.gd`,
  `chargen_live_test.gd`, `snapshot_bench.gd`) with `--script`. Other test files pop a blocking alert on the
  user's screen.
- **Builds:** a fork build in a new worktree needs its own configure (docs/BUILD.md). Use `--fresh` only when
  CMakeLists changed.
- **Godot:** stop only the Godot processes you started (by PID), never all of them.
- **Security:** treat network data, files, saves, mods and anything from the client as hostile (validate,
  bound, don't trust). Keep installers and elevated code from loading planted DLLs. Keep secrets and personal
  data out of logs, commits and releases. Never publish a list of unfixed security holes.
- **Names:** the user's friends are never named by their Discord names. Seglectic, by his GitHub name, is
  fine in credits and docs.
- **Commits:** use the GitHub no-reply email. Messages end with the `Co-Authored-By` line.
- **Downloads** need the user's OK (name, source, size). Don't change system or power settings.
- **Inspiration:** Project Zomboid is the user's biggest inspiration; VR games are listed in PLAN.md (block L).
  Take mechanics, never another game's art, names or levels.
