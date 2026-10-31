# UI requests (sim ⇄ client)

The key to M2. CDDA asks for input from deep inside game logic and blocks until it gets an answer. In libcdda
the sim runs on its own thread; each blocking call below is replaced (behind `// FP3D:` hooks) by "post a
request, wait for the answer". The client shows a generic widget (block E3) and sends back `answer`. Native UIs
(block G) later take over specific request kinds without touching the sim.

| Request kind | Payload to client | Answer | CDDA call sites to route |
|---|---|---|---|
| `yes_no` | text | bool | `query_yn` (output.cpp) |
| `popup` | text, options (ok / any key) | key/ok | `popup`, `query_popup` |
| `menu` | title, text, entries [{id, label, enabled, hotkey, description}], selected | entry id or cancel | `uilist` (uilist.h) |
| `string` | title, description, default, max_len | string or cancel | `string_input_popup` |
| `number` | title, min, max, default | int or cancel | `string_input_popup` (numeric) / `query_int` |
| `direction` | prompt, allow_vertical | dir or cancel | `choose_direction`, `choose_adjacent` |
| `target` | mode (look/aim/throw/spell), range, candidates [uid/pos] | pos/uid or cancel | `target_handler`, `look_around` |
| `item_select` | title, items [{handle, name, count, location}], multi | handles (+counts) or cancel | inventory selectors (`game_inventory`) |
| `key` | context name, allowed action ids | action id | `input_context::handle_input` when no other kind fits |

### Implemented (`cdda/src/fp3d/bridge.h`)

| `request_kind` | Hooked at | Answer fields |
|---|---|---|
| `key` | `input_context::handle_input` (context = input category, `actions` = registered actions); raw `input_manager::get_input_event` reads use context `RAW_KEY` | `action` (must be in `actions`; cancel → `QUIT` if registered) |
| `menu` | `uilist::query` (entry id = retval) | `entry` or cancel |
| `popup` | `query_popup::query` (covers `query_yn`, `popup`) | `action` (one of `actions`) or cancel |
| `string` | `string_input_popup::query_string` (default text in `entries[0].label`) | `text` (control chars stripped, capped) or cancel |
| `item_select` | `inventory_pick_selector::execute` (eat, wield, read, …) | `entry` or cancel |
| `item_multi` | `pickup_selector`, `inventory_drop_selector`, `inventory_multiselector` `execute` | `picks` [(entry, count 0 = all)] or cancel |
| `direction` | `choose_direction` / `choose_adjacent` (`text` = "Open where?", `origin`, `allow_vertical`) | `pos` = relative vector, each axis −1..1 (z 0 unless vertical); anything else = cancel |
| `target` | `game::look_around` (`mode` look / zone / peek) and `target_ui::run` (`mode` fire / throw / throw_blind / turrets / turret_manual / reach / spell / select) | `pos` = absolute square (clamped by CDDA's cursor rules) and/or `action` from `actions` (FIRE, AIM, STOPAIM, aim shots, SWITCH_MODE, …); a square with no action asks again with the new `status`; cancel = abort |

Target requests carry `origin`, `cursor`, `range`, `status` ("" or bad_target / out_of_ammo / out_of_range)
and `candidates` (absolute squares of visible creatures; hostiles only when aiming; capped at 256). Peeking's
blind throw/fire isn't offered yet.

Every request carries `turn` (game turns since the cataclysm), `paused` and `pause_reason`. The main game loop's
request (`game::get_player_input`) is `timed`; every other input loop that polls with a timeout gets `TIMEOUT`
without asking (`fp3d::poll_report()` counts them). While the bridge is active, `ui_manager::redraw`,
`refresh_display` and `curses_drawwindow` draw nothing, and CDDA's own SDL window exists but is hidden (game
code calls its tile renderer directly).

### Clock (block D3: `fp3d::set_clock_mode`, `set_timescale`, `set_paused`)

- **Turn-based** (default): the sim waits for the player, like CDDA.
- **Real time**: each turn lasts 1 s / timescale (0.25–16) of wall time. `do_turn` waits out the rest of the
  turn; a `timed` request still unanswered when the turn ends expires (the answer comes back `timed_out`) and the
  player waits (`pause`). A late answer to an expired id is ignored: the client re-sends its action to the next
  request. Activities and sleep fast-forward.
- **Pause** stops turns in both modes (at the next turn boundary; a pending request doesn't expire). The sim
  auto-pauses real time when safe mode stops for a new monster (`pause_reason` "hostile spotted"); only the
  client resumes.
- **Interrupt**: `fp3d::interrupt()` stops the current activity (CDDA confirms with a popup first).

Verified by `fp3d-sim-test`: a real `start_game()` character opens a door (`direction`), picks up an apple
(`item_multi`), eats it (`item_select` + `popup`), looks (`target`/look), throws a rock at a square
(`target`/throw + FIRE), waits 5 minutes (`menu`, 300 turns of activity), runs 3 real-time turns at 4×, is
auto-paused by a zombie and resumed, then saves, quits and reloads with the world intact.

Rules
- One outstanding request at a time per sim thread; requests carry an `id`; answers with a wrong id are ignored.
- Every request has a **cancel** path; the client shows it, and closing the window sends cancel.
- Answers are validated (entry id exists and is enabled, number in range, handle was offered). Strings are length
  capped and stripped of control characters; coordinates beyond ±2^28 are dropped.
- Text is CDDA's own colour-tagged text (`<color_x>`); the client converts tags to rich text.
