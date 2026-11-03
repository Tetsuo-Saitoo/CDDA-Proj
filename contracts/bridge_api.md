# Bridge API (GDExtension `CddaSim`)

The DLL `client/bin/fp3d_cdda.windows.x86_64.dll` (loaded by `client/bin/fp3d_cdda.gdextension`) runs CDDA
inside the Godot process on its own thread and registers one class, `CddaSim` (a `RefCounted`). CDDA's state is
global, so every `CddaSim` talks to the same single game. Source: `bridge/src/`; build: `docs/BUILD.md`.

Scripts should not name `CddaSim` as a type (the client must still load when the DLL isn't built): check
`ClassDB.class_exists("CddaSim")` and use `ClassDB.instantiate("CddaSim")`. `client/scripts/live/live_session.gd`
wraps it for the client.

All methods are non-blocking except `stop()`. Everything is polled; there are no signals.

| Method | Returns | Notes |
|---|---|---|
| `start(data_dir, user_dir, world)` | `String` | "" when started, otherwise why not. `data_dir`: absolute, holds `data/json` (the `cdda/` folder). `user_dir`: absolute, made if missing; config, saves and `config/debug.log` go there. `world`: 1-32 of `A-Z a-z 0-9 _ -`; **an existing world of that name is deleted** and a new game with a random character starts. Once per process. |
| `stop()` | | Shuts the game down and waits for its thread. While booting this waits until loading is done (up to ~30 s). The extension calls it on unload. No restart afterwards (once per process). |
| `get_state()` | `String` | `idle`, `booting`, `running`, `ended` (death or quit), `failed` (an exception), `stopped`. |
| `get_error()` | `String` | Why it ended or failed. |
| `get_request()` | `Dictionary` | The pending UI request, `{}` if none. Fields as in `ui_requests.md`: `id`, `kind` (key, menu, popup, string, item_select, item_multi, direction, target), `context`, `title`, `text`, `entries` (Array of `{id, label, enabled, description}`), `actions` (PackedStringArray), `allow_cancel`, `max_len`, `mode`, `status`, `origin`, `cursor` (Vector3i), `range`, `allow_vertical`, `candidates` (Array of Vector3i), `timed`, `turn`, `paused`, `pause_reason`. Compare `id` to see a new one. |
| `answer(d)` | `bool` | Answers the pending request. `d`: `id` (int, required), optional `cancel` (bool), `action` (String, ≤64 bytes), `entry` (int), `text` (String, ≤1024 bytes), `picks` (Array of `[entry id, count]`, count 0 = all, ≤4096), `pos` (Vector3i). Any field of the wrong type → `false` and nothing is sent. Strings lose control characters. A stale `id` is ignored by the sim. |
| `queue_action(action)` / `clear_actions()` / `get_queued_actions()` | `bool` / / `int` | The action queue (`ui_requests.md`): main-loop action names (`UP`, `pause`, `LEVEL_UP`, ...), max 32. |
| `get_snapshot_seq()` | `int` | seq of the newest snapshot, 0 before the first. A snapshot is taken right before every request. |
| `get_snapshot_json(z_below, z_above)` | `String` | The newest snapshot as `snapshot.md` JSON, levels from the player's z − `z_below` to z + `z_above`. "" before the first. Treat as hostile input like any snapshot (`Snapshot.parse_text`). |
| `get_id_tables_json()` | `String` | `id_tables.md` JSON; "" before the data has loaded. Fetch again when a snapshot's `ids_generation` changes. |
| `drain_events()` | `Array` | Events since the last call (`events.md`), each a Dictionary: `kind` (sound, message, attack, damage, projectile, explosion, death, anim, turn_end), `turn`, `seq`, `uid`, `other`, `pos` (Vector3i), `amount`, `heard`, `type`, `detail`, `text`, `path` (Array of Vector3i). Drain every frame: the queue holds 4096. |
| `get_events_dropped()` | `int` | Events lost to overflow since start. |
| `get_clock()` | `Dictionary` | `real_time`, `timescale`, `paused`, `pause_reason`. |
| `set_real_time(on)` / `set_timescale(s)` / `set_paused(on)` / `interrupt()` | | The clock (`ui_requests.md`); timescale clamps to 0.25-16. |

Positions are absolute map squares (CDDA `tripoint_abs_ms`, y south), like the snapshot.

## Behaviour to know

- Boot takes ~30 s (data load, new game). The first snapshot arrives with the first request.
- CDDA's debug message prompts and "press any key" screens come as `key` requests with context `RAW_KEY` and no
  actions; answer `action: " "`. The message itself is in `debug.log`.
- CDDA's window still exists, hidden, with SDL's software renderer (B2 tech debt); it is created and destroyed
  on the game thread, which also calls `SDL_Quit()` before it ends (see TASKS.md "Bridge facts").
- The DLL links everything statically (vcpkg `x64-windows-static`, static CRT): it imports only system DLLs.
- `get_snapshot_json` builds the JSON on the calling thread (~tens of ms for 3 levels); call it only when the seq
  changes.
