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

Rules
- One outstanding request at a time per sim thread; requests carry an `id`; answers with a wrong id are ignored.
- Every request has a **cancel** path; the client shows it, and closing the window sends cancel.
- Answers are validated (entry id exists and is enabled, number in range, handle was offered). Strings are length
  capped and stripped of control characters.
- Text is CDDA's own colour-tagged text (`<color_x>`); the client converts tags to rich text.
