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
| `item_select` | `inventory_pick_selector::execute` (eat, wield, read, …), `ammo_inventory_selector::execute` (the ammo to reload with) | `entry` or cancel |
| `item_multi` | `pickup_selector`, `inventory_drop_selector`, `inventory_multiselector` `execute` | `picks` [(entry, count 0 = all)] or cancel |
| `direction` | `choose_direction` / `choose_adjacent` (`text` = "Open where?", `origin`, `allow_vertical`) | `pos` = relative vector, each axis −1..1 (z 0 unless vertical); anything else = cancel |
| `target` | `game::look_around` (`mode` look / zone / peek) and `target_ui::run` (`mode` fire / throw / throw_blind / turrets / turret_manual / reach / spell / select) | `pos` = absolute square (clamped by CDDA's cursor rules) and/or `action` from `actions` (FIRE, AIM, STOPAIM, aim shots, SWITCH_MODE, …); a square with no action asks again with the new `status`; cancel = abort |
| `world_setup` | `fp3d::run_world_setup` (`cdda/src/fp3d/worldgen.h`), for a fresh world started with `start_new_game(..., world_setup = true)`, before character creation | `text` = JSON `{"sliders": {id: level}, "options": {id: value}, "mods": [ids]}` (cap 16 KB; omitted parts keep defaults). The request's `text` is the catalog: `sliders` (CDDA's WORLDGEN option sliders: id, name, default, levels with name/description), `options` (shown world settings: id, name, tooltip, type bool/int/int_map/float/string_select/string_input with value, min/max/step or choices or max_length), `mods` (usable, non-obsolete: id, name, description, category, core, dependencies, conflicts) and `default_mods`. Sliders apply first, options on top; hidden options only through sliders; dependencies are added (core first); exactly one core mod; conflicts refused. Bad answers are asked again with `status`; cancel ends the boot (`world creation cancelled`). Client: `WorldSetup` model + `WorldSetupRequestWidget`. |
| `shot` | `projectile_attack` (ballistics.cpp), once per projectile of a trigger pull whose FIRE answer had `shot.fly` (see below). `shot_error` (arcmin CDDA rolled for this projectile), `shot_angle` (degrees 0..360, which way off the sight line: 0 up, 90 the shooter's right), `dispersion` (arcmin, the max), `origin`, `cursor`, `range` | `shot` = {end, hit_uid, part, quality} where that bullet went, or cancel (CDDA rolls it) |
| `chargen` | `fp3d::run_chargen` (`cdda/src/fp3d/chargen.h`), at a new game started with `start_new_game(..., chargen = true)`, before `start_game` | `text` = the choices as JSON (cap 16 KB): `scenario`, `profession`, `backgrounds` [ids; omitted = CDDA's default], `str`/`dex`/`int`/`per`, `traits` [ids, besides the locked ones], `skills` {id: level}, `name` ("" = random), `male`, `age`, `height`, optional `save_template` (name: also saves it as a CDDA template). Or just `{"template": name, "name": ""}` to start from a template the catalog's `templates` lists, or `{"delete_template": name}` to delete one (re-asked with a fresh catalog and `status` "deleted template …"). The catalog's `template_choices` gives each template's contents in the answer format, for editing. The request's `text` is the catalog JSON (pool rules, `skill_costs`, ranges, `scenarios` with their `professions`/`backgrounds`/`extra_traits`/`forbidden_traits`/`locked_traits`, `professions`, `backgrounds`, `traits` with `points`/`starting`/`cancels`/`types`, `skills`); invalid choices are asked again with `status` saying why; cancel ends the boot (`failed`, "character creation cancelled"). Points are only enforced with CDDA's `multi_pool` option (default `story_teller` = freeform). Client: `Chargen` model + `ChargenRequestWidget`. |

Target requests carry `origin`, `cursor`, `range`, `status` ("" or bad_target / out_of_ammo / out_of_range)
and `candidates` (absolute squares of visible creatures; hostiles only when aiming; capped at 256). Peeking's
blind throw/fire isn't offered yet.

Client aiming (AimController): the 3D view picks `pos` with a camera ray (click a creature or square, a
second click or F / pad R1 fires); holding RMB in first person aims with a centre crosshair like an FPS (attack
modes only) and LMB fires with the primary action (FIRE, else CONFIRM / SELECT). CDDA still checks range and
line of fire.

Client-flown shots (`cdda/src/fp3d/shot.h`). Fire-mode target requests with a gun also carry `dispersion`
(arcmin: the max error after aiming in the current aim mode, as CDDA's aim panel predicts it),
`dispersion_typical` (arcmin, the average; both only when > 0) and `weapon_wielded` (the gun is the avatar's
wielded item and its current mode fires the gun itself, not a gunmod; the client flies shots only then). A FIRE (or aim-and-shoot) answer may carry `shot` = {end:
Vector3i (absolute square where the bullet stopped), hit_uid (creature hit, 0 = miss), part (character body
part id like head / arm_l, or monster weak point id like head / eye / leg; "" = CDDA picks), quality (float 0
dead centre .. 0.99), fly (bool, anything else = false)}. CDDA's dispersion roll decides every projectile:
- The answer is stored only for a fire-mode answer that fires the avatar's wielded gun and isn't a cancel, and
  holds only for a trigger pull of that gun at that answer's square; throws, turrets, spells, gunmod modes and
  NPCs never use it. Aiming that ends without a shot (cancelled, interrupted, aborted) drops it. Without `fly`,
  its outcome applies to the trigger pull's first projectile only, on the game turn of the answer (an aimed shot
  that fires on a later turn drops it).
- With `fly`, each projectile (each round of a burst; a shotgun shell is one, its pellets spread around it) sends
  one `shot` request with the error CDDA rolled (at most 1800 arcmin); the client turns its sight line by it,
  flies that bullet against the figures it already shows (no new snapshot comes with a `shot` request) and
  answers with `shot` {end, hit_uid, part, quality}. The sim waits for one answer per projectile. A cancel, a
  missing `shot` or one that fails the checks leaves that projectile to CDDA's own path (the FIRE answer's
  outcome is not used with `fly`).
- Checks: quality finite (clamped 0..0.99); a hit names the cursor creature or a candidate, alive and seen now
  (the bullet stops at its square); a miss's `end` is in the bubble; the square is on the shooter's z, in
  front of it, within the gun's range for the avatar, and near the line: within 1 square of the line to the
  cursor (FIRE answer) or 1.5 squares of CDDA's deviated line (shot answer: the line turned by
  shot_error * sin(shot_angle) to the shooter's right). Anything else is ignored and CDDA's own path runs.
- Outcome: a client hit counts only if the creature's own roll hits: CDDA's roll for the aimed square's creature;
  for another creature, its square's distance off the projectile's line against its ranged size: CDDA's deviated
  line combined with the error's vertical part (shot_error * cos(shot_angle)) over the distance along it (shot
  answer), or the aim line plus the whole error in the worst direction (FIRE answer); a HARDTOHIT character: the
  worse of two rolls, as CDDA does. goodhit = max(that roll, quality); when the roll misses, CDDA's own path runs.
- A client miss never picks the direction: the projectile flies CDDA's line (the deviated line for a shot answer,
  the aim line for a FIRE answer; a FIRE answer's miss when CDDA's own roll is a square or more off takes CDDA's
  own wild-miss path) out to the aimed distance and on as CDDA's overshoot would. `end` only stops it early, at
  its distance along that line, where the line's square there is impassable (wall, closed door, solid
  furniture). Other creatures on the path get CDDA's rolls, the aimed one no better than CDDA's own (a CDDA miss
  stays a miss). The client can make a shot worse, never better.
- Part: looked up by name (body parts of the character, weak points of the monster's type; 64 bytes max); it
  lands only if goodhit <= sqrt(hit chance / 100) (weak point: `weakpoint::hit_chance`; body part: its share of
  the body's hit size), else CDDA picks. Ignored on other requests.
Anything else (ammo, recoil, noise, time, damage, armour) is CDDA's.

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
  auto-pauses real time when a new hostile comes into view (`pause_reason` "hostile spotted"; where CDDA's safe
  mode would stop you) unless the client turned that off (`set_auto_pause_hostiles`); only the client resumes.
  CDDA's safe mode itself is off in FP3D games, new and loaded (`safemode` toggles it).
- **Interrupt**: `fp3d::interrupt()` stops the current activity (CDDA confirms with a popup first).

### Action queue (block B5: `fp3d::queue_action`, `clear_actions`, `queued_actions`)

The client doesn't have to catch each `timed` request: it can queue main-loop actions (names as in a timed
request's `actions`) at any time, up to 32 (`queue_action` returns false when full). The sim takes one per timed
request before waiting, under the lock that posts the request, so the client only ever sees a timed request when
the queue is empty. Nothing is taken while paused. An action that isn't valid there is dropped with a `message`
event ("Can't do that here: …"). Auto-pause clears the queue. Menus and other untimed requests are still answered
with `answer()`. Asking again after a bad answer keeps the request `timed` (fixed in B5: it used to lose the flag).

Threads: the sim runs on its own thread; the client polls `wait_request( 0 )`, `latest_snapshot()` and
`drain_events()` from its frame loop and never blocks. All of them are mutex-guarded handoffs.

Verified by `fp3d-sim-test`: a real `start_game()` character opens a door (`direction`), picks up an apple
(`item_multi`), eats it (`item_select` + `popup`), looks (`target`/look), throws a rock at a square
(`target`/throw + FIRE), waits 5 minutes (`menu`, 300 turns of activity), runs 3 real-time turns at 4×, is
auto-paused by a zombie and resumed, then saves, quits and reloads with the world intact. Then it queues a bad
action and three `pause`s with the zombie still in view (all run, 3 turns pass, no answers; safe mode is off),
checks the queue waits while paused and refuses a 33rd action; then checks safe mode is off in the new and the
loaded game, `safemode` turns it on and off, and real time runs on past a new zombie with auto-pause off.

Rules
- One outstanding request at a time per sim thread; requests carry an `id`; answers with a wrong id are ignored.
- Every request has a **cancel** path; the client shows it, and closing the window sends cancel.
- Answers are validated (entry id exists and is enabled, number in range, handle was offered). Strings are length
  capped and stripped of control characters; coordinates beyond ±2^28 are dropped.
- Text is CDDA's own colour-tagged text (`<color_x>`); the client converts tags to rich text
  (`client/scripts/ui/cdda_text.gd`; the renderer is `client/scripts/ui/request_ui.gd`).
