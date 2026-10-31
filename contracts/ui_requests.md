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

### Implemented in slice 1 (`cdda/src/fp3d/bridge.h`)

| `request_kind` | Hooked at | Answer fields |
|---|---|---|
| `key` | `input_context::handle_input` (context = input category, `actions` = registered actions); raw `input_manager::get_input_event` reads use context `RAW_KEY` | `action` (must be in `actions`; cancel → `QUIT` if registered) |
| `menu` | `uilist::query` (entry id = retval) | `entry` or cancel |
| `popup` | `query_popup::query` (covers `query_yn`, `popup`) | `action` (one of `actions`) or cancel |
| `string` | `string_input_popup::query_string` (default text in `entries[0].label`) | `text` (control chars stripped, capped) or cancel |
| `item_select` | `inventory_pick_selector::execute` (eat, wield, read, …) | `entry` or cancel |
| `item_multi` | `pickup_selector`, `inventory_drop_selector`, `inventory_multiselector` `execute` | `picks` [(entry, count 0 = all)] or cancel |

Direction prompts (`choose_direction`) arrive as `key` requests in context `DEFAULTMODE` with directions,
`pause` (own tile) and `QUIT`, and `text` = CDDA's prompt ("Open where?"). The main game loop
(`game::get_player_input`) and direction prompts block on the client; every other input loop that polls with a
timeout gets `TIMEOUT` without asking (`fp3d::poll_report()` counts them). While the bridge is active,
`ui_manager::redraw`, `refresh_display` and `curses_drawwindow` draw nothing, and CDDA's own SDL window exists
but is hidden (game code calls its tile renderer directly).

Verified by `fp3d-sim-test` (2026-10-30): a real `start_game()` character opens a door, picks up an apple
(`item_multi`) and eats it (`item_select`, then a `popup`), with all results checked from game state.

Rules
- One outstanding request at a time per sim thread; requests carry an `id`; answers with a wrong id are ignored.
- Every request has a **cancel** path; the client shows it, and closing the window sends cancel.
- Answers are validated (entry id exists and is enabled, number in range, handle was offered). Strings are length
  capped and stripped of control characters.
- Text is CDDA's own colour-tagged text (`<color_x>`); the client converts tags to rich text.
