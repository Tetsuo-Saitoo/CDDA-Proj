# Actions (client → sim)

What the player wants. The sim validates each one exactly as if it came from CDDA's keyboard path; an invalid
action is rejected with a `message` event, never applied partly.

| Action | Fields | Maps to |
|---|---|---|
| `raw_action` | `action_id` name (string from `action.h`) | `game::handle_action` path; the catch-all that keeps every CDDA command reachable (M2) |
| `step` | direction (8-way + up/down) | `avatar_action::move` (M2, tile movement) |
| `move_vector` | desired velocity vec2 (m/s, already limited by client to move mode max), dt | continuous movement (block D1, M3) |
| `look` | facing_deg, pitch_deg | facing for sight cone, aim, sprite facing |
| `set_move_mode` | walk/run/crouch/prone | `avatar::set_movement_mode` |
| `interact` | target: tile pos \| vehicle part (uid, mount) \| item (pos, index) \| creature uid; verb (optional) | examine / open / close / pickup / talk |
| `attack` | target uid or pos (+subtile aim point), mode (melee/fire/throw), aim_turns | melee / `avatar::fire_gun` / throw |
| `use_item` | item location handle, verb | activate, wear, wield, eat, read, reload |
| `time` | pause \| resume \| timescale (0.25–16) \| wait N turns | real-time clock (block D3) |
| `answer` | request id + payload | reply to a `ui_request` |

Item location handles are opaque tokens issued in snapshots/ui_requests and expire after N turns, so the client
can never point at memory or items it was not shown.
